-- n8n-wms: business logic.
--
-- Why this is SQL and not n8n nodes: every warehouse movement is at least two
-- writes (a ledger row and an on-hand change) that must never diverge, and n8n
-- gives each Postgres node its own connection and statement, with no way to
-- wrap several nodes in one transaction. So each mutation is a single function
-- call that does all of its writes atomically, with SELECT ... FOR UPDATE where
-- operators could collide. Cost: about 3 ms per call. Proven under contention
-- in bench/: 400 concurrent receipts of one article leave on_hand, ledger rows
-- and ledger sum at exactly 400.
--
-- The consequence, and the main finding of the project: the business logic
-- lives here, not on the n8n canvas. See docs/FEASIBILITY.md.
--
-- Every function is schema-qualified and safe to (re)create with an empty
-- search_path.

-- ==========================================================================
-- Sessions -- the terminal state machine's storage
-- ==========================================================================

CREATE OR REPLACE FUNCTION wms.session_start(p_badge text) RETURNS TABLE(token text, user_id bigint, user_name text, state text, context jsonb)
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_user wms.users%ROWTYPE;
  v_sess wms.operator_sessions%ROWTYPE;
BEGIN
  SELECT * INTO v_user FROM wms.users u WHERE u.badge_code = p_badge AND u.active;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT * INTO v_sess FROM wms.operator_sessions s
   WHERE s.user_id = v_user.id AND s.last_seen_at > now() - INTERVAL '12 hours'
   ORDER BY s.last_seen_at DESC LIMIT 1;

  IF NOT FOUND THEN
    INSERT INTO wms.operator_sessions (token, user_id)
    -- Two UUIDv4s with the dashes stripped: 64 hex characters, 244 bits of
    -- randomness from the same CSPRNG pgcrypto would have used, and no
    -- extension required on the host database.
    VALUES (replace(gen_random_uuid()::text, '-', '')
            || replace(gen_random_uuid()::text, '-', ''), v_user.id)
    RETURNING * INTO v_sess;
  ELSE
    UPDATE wms.operator_sessions s SET last_seen_at = now()
     WHERE s.token = v_sess.token RETURNING * INTO v_sess;
  END IF;

  token     := v_sess.token;
  user_id   := v_user.id;
  user_name := v_user.name;
  state     := v_sess.state;
  context   := v_sess.context;
  RETURN NEXT;
END $$;

CREATE OR REPLACE FUNCTION wms.session_touch(p_token text) RETURNS TABLE(token text, user_id bigint, user_name text, state text, context jsonb)
    LANGUAGE plpgsql
    AS $$
DECLARE v_sess wms.operator_sessions%ROWTYPE;
BEGIN
  UPDATE wms.operator_sessions s SET last_seen_at = now()
   WHERE s.token = p_token AND s.last_seen_at > now() - INTERVAL '12 hours'
   RETURNING * INTO v_sess;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  token   := v_sess.token;
  user_id := v_sess.user_id;
  state   := v_sess.state;
  context := v_sess.context;
  SELECT u.name INTO user_name FROM wms.users u WHERE u.id = v_sess.user_id;
  RETURN NEXT;
END $$;

CREATE OR REPLACE FUNCTION wms.session_set_state(p_token text, p_state text, p_context jsonb DEFAULT NULL::jsonb, p_replace boolean DEFAULT false) RETURNS TABLE(token text, state text, context jsonb)
    LANGUAGE plpgsql
    AS $$
DECLARE v_sess wms.operator_sessions%ROWTYPE;
BEGIN
  UPDATE wms.operator_sessions s
     SET state = p_state,
         context = CASE
                     WHEN p_context IS NULL THEN s.context
                     WHEN p_replace THEN p_context
                     ELSE s.context || p_context
                   END,
         last_seen_at = now()
   WHERE s.token = p_token
   RETURNING * INTO v_sess;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  token   := v_sess.token;
  state   := v_sess.state;
  context := v_sess.context;
  RETURN NEXT;
END $$;

-- ==========================================================================
-- Reads -- one call per screen, one call per scan
-- ==========================================================================

CREATE OR REPLACE FUNCTION wms.screen_data(p_token text) RETURNS TABLE(state text, user_id bigint, user_name text, context jsonb, payload jsonb)
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_sess    wms.operator_sessions%ROWTYPE;
  v_state   TEXT;
  v_ctx     JSONB;
BEGIN
  -- No cookie, unknown cookie, or an expired one all mean the same thing to the
  -- caller: show the login screen. Returning a row with state='login' rather
  -- than zero rows keeps the n8n side from needing an "empty result" branch.
  IF p_token IS NULL OR p_token = '' THEN
    state := 'login'; payload := '{}'::jsonb; RETURN NEXT; RETURN;
  END IF;

  UPDATE wms.operator_sessions s SET last_seen_at = now()
   WHERE s.token = p_token AND s.last_seen_at > now() - INTERVAL '12 hours'
   RETURNING * INTO v_sess;

  IF NOT FOUND THEN
    state := 'login'; payload := '{}'::jsonb; RETURN NEXT; RETURN;
  END IF;

  v_state := v_sess.state;
  v_ctx   := v_sess.context;

  state     := v_state;
  user_id   := v_sess.user_id;
  context   := v_ctx;
  SELECT u.name INTO user_name FROM wms.users u WHERE u.id = v_sess.user_id;

  IF v_state = 'idle' THEN
    SELECT jsonb_build_object(
      'open_receipts', (SELECT count(*) FROM wms.open_receipt_lines),
      'open_picks',    (SELECT count(*) FROM wms.pick_tasks WHERE status IN ('open','in_progress')),
      'open_putaways', (SELECT count(*) FROM wms.putaway_tasks WHERE status = 'open')
    ) INTO payload;

  ELSIF v_state = 'receiving_await_po' THEN
    SELECT jsonb_build_object(
      'orders', COALESCE(jsonb_agg(DISTINCT jsonb_build_object(
                  'order_number', r.order_number, 'vendor', r.vendor,
                  'open_lines', 1)), '[]'::jsonb)
    ) INTO payload FROM wms.open_receipt_lines r;

  ELSIF v_state IN ('receiving_await_item', 'receiving_await_qty') THEN
    SELECT jsonb_build_object(
      'order_number', po.order_number,
      'vendor',       po.vendor,
      'lines', COALESCE((
        -- barcode travels with every line because the screen has to show the
        -- operator what to actually scan. Without it the list reads "SKU-1004"
        -- while the label on the carton says "4000000001004", and a first-time
        -- user types the SKU and gets "unknown barcode". A warehouse operator
        -- with a real scanner never notices; anyone evaluating the demo by hand
        -- is stopped dead. Same reason locations carry theirs below.
        SELECT jsonb_agg(jsonb_build_object(
                 'po_line_id', r.po_line_id, 'line_number', r.line_number,
                 'product_id', r.product_id,
                 'sku', r.sku, 'product_name', r.product_name,
                 'barcode', (SELECT b.barcode FROM wms.barcode_mappings b
                              WHERE b.entity_type = 'product' AND b.entity_id = r.product_id),
                 'ordered_qty', r.ordered_qty, 'received_qty', r.received_qty,
                 'open_qty', r.open_qty) ORDER BY r.line_number)
          FROM wms.open_receipt_lines r
         WHERE r.purchase_order_id = po.id), '[]'::jsonb),
      'current_line', (
        SELECT jsonb_build_object('po_line_id', r.po_line_id, 'sku', r.sku,
                 'product_name', r.product_name, 'open_qty', r.open_qty,
                 'barcode', (SELECT b.barcode FROM wms.barcode_mappings b
                              WHERE b.entity_type = 'product' AND b.entity_id = r.product_id))
          FROM wms.open_receipt_lines r
         WHERE r.po_line_id = (v_ctx->>'po_line_id')::BIGINT)
    ) INTO payload
    FROM wms.purchase_orders po
   WHERE po.id = (v_ctx->>'po_id')::BIGINT;

  ELSIF v_state IN ('picking_await_location', 'picking_await_item', 'picking_await_qty') THEN
    SELECT jsonb_build_object(
      'task_id',       t.id,
      'order_number',  so.order_number,
      'customer',      so.customer,
      'sku',           p.sku,
      'product_name',  p.name,
      'location_code', l.code,
      -- The two values the operator must actually scan on the picking screens.
      -- The location's code is "C-01-1" but its label reads "LOC-C-01-1"; the
      -- article's SKU is "SKU-1009" but its label reads "4000000001009".
      -- Showing the code without the barcode is showing the wrong string.
      'location_barcode', (SELECT b.barcode FROM wms.barcode_mappings b
                            WHERE b.entity_type = 'location' AND b.entity_id = t.location_id),
      'product_barcode',  (SELECT b.barcode FROM wms.barcode_mappings b
                            WHERE b.entity_type = 'product' AND b.entity_id = t.product_id),
      'qty',           t.qty,
      'on_hand',       COALESCE((SELECT i.qty FROM wms.inventory i
                                  WHERE i.product_id = t.product_id
                                    AND i.location_id = t.location_id), 0),
      'remaining_tasks', (SELECT count(*) FROM wms.pick_tasks x
                           WHERE x.status IN ('open','in_progress'))
    ) INTO payload
    FROM wms.pick_tasks t
    JOIN wms.products p  ON p.id = t.product_id
    JOIN wms.locations l ON l.id = t.location_id
    JOIN wms.sales_order_lines sol ON sol.id = t.sales_order_line_id
    JOIN wms.sales_orders so ON so.id = sol.sales_order_id
   WHERE t.id = (v_ctx->>'task_id')::BIGINT;

  ELSIF v_state = 'lookup' THEN
    SELECT jsonb_build_object(
      'product', CASE WHEN v_ctx ? 'product_id' THEN (
         SELECT jsonb_build_object('sku', p.sku, 'name', p.name, 'uom', p.uom,
                  'total', COALESCE((SELECT sum(i.qty) FROM wms.inventory i
                                      WHERE i.product_id = p.id), 0),
                  'locations', COALESCE((
                     SELECT jsonb_agg(jsonb_build_object(
                              'location_code', s.location_code,
                              'location_kind', s.location_kind,
                              'qty', s.qty) ORDER BY s.location_code)
                       FROM wms.stock_on_hand s WHERE s.product_id = p.id), '[]'::jsonb))
           FROM wms.products p WHERE p.id = (v_ctx->>'product_id')::BIGINT)
       ELSE NULL END
    ) INTO payload;
  END IF;

  payload := COALESCE(payload, '{}'::jsonb);
  RETURN NEXT;
END $$;

CREATE OR REPLACE FUNCTION wms.resolve_barcode(p_barcode text) RETURNS TABLE(entity_type text, entity_id bigint, label text, detail text)
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE m wms.barcode_mappings%ROWTYPE;
BEGIN
  SELECT * INTO m FROM wms.barcode_mappings b WHERE b.barcode = p_barcode;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  entity_type := m.entity_type;
  entity_id   := m.entity_id;

  CASE m.entity_type
    WHEN 'product' THEN
      SELECT p.name, p.sku INTO label, detail FROM wms.products p WHERE p.id = m.entity_id;
    WHEN 'location' THEN
      SELECT l.code, l.kind INTO label, detail FROM wms.locations l WHERE l.id = m.entity_id;
    WHEN 'user' THEN
      SELECT u.name, u.role INTO label, detail FROM wms.users u WHERE u.id = m.entity_id;
    WHEN 'purchase_order' THEN
      SELECT po.order_number, po.vendor INTO label, detail
        FROM wms.purchase_orders po WHERE po.id = m.entity_id;
    WHEN 'sales_order' THEN
      SELECT so.order_number, so.customer INTO label, detail
        FROM wms.sales_orders so WHERE so.id = m.entity_id;
  END CASE;

  RETURN NEXT;
END $$;

CREATE OR REPLACE FUNCTION wms.find_receipt_line(p_po_id bigint, p_product_id bigint) RETURNS TABLE(po_line_id bigint, sku text, product_name text, open_qty integer)
    LANGUAGE sql STABLE
    AS $$
  SELECT r.po_line_id, r.sku, r.product_name, r.open_qty
    FROM wms.open_receipt_lines r
   WHERE r.purchase_order_id = p_po_id AND r.product_id = p_product_id
   ORDER BY r.line_number
   LIMIT 1;
$$;

-- ==========================================================================
-- The ledger -- every stock movement goes through here
-- ==========================================================================

CREATE OR REPLACE FUNCTION wms.apply_movement(p_product_id bigint, p_location_id bigint, p_delta integer, p_reason text, p_user_id bigint, p_reference_type text DEFAULT NULL::text, p_reference_id bigint DEFAULT NULL::bigint) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE v_new_qty INTEGER;
BEGIN
  -- ON CONFLICT ... DO UPDATE takes the row lock for us, so two operators
  -- touching the same product/location serialise here rather than racing.
  INSERT INTO wms.inventory (product_id, location_id, qty, updated_at)
  VALUES (p_product_id, p_location_id, GREATEST(p_delta, 0), now())
  ON CONFLICT (product_id, location_id) DO UPDATE
    SET qty = wms.inventory.qty + p_delta, updated_at = now()
  RETURNING qty INTO v_new_qty;

  -- The CHECK (qty >= 0) fires before this if the move would go negative, which
  -- is the intended behaviour: refuse the movement rather than record an
  -- impossible stock level.
  INSERT INTO wms.inventory_transactions
    (product_id, location_id, delta, reason, user_id, reference_type, reference_id)
  VALUES (p_product_id, p_location_id, p_delta, p_reason, p_user_id,
          p_reference_type, p_reference_id);

  RETURN v_new_qty;
END $$;

CREATE OR REPLACE FUNCTION wms.adjust_stock(p_product_id bigint, p_location_id bigint, p_counted_qty integer, p_user_id bigint, p_reason text DEFAULT 'count'::text) RETURNS TABLE(product_name text, location_code text, previous_qty integer, on_hand integer, delta integer)
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_prev  INTEGER;
  v_delta INTEGER;
  v_new   INTEGER;
BEGIN
  SELECT COALESCE(i.qty, 0) INTO v_prev FROM wms.inventory i
   WHERE i.product_id = p_product_id AND i.location_id = p_location_id;
  v_prev  := COALESCE(v_prev, 0);
  v_delta := p_counted_qty - v_prev;

  IF v_delta = 0 THEN
    v_new := v_prev;
  ELSE
    v_new := wms.apply_movement(p_product_id, p_location_id, v_delta,
                                p_reason, p_user_id, 'adjustment', NULL);
  END IF;

  previous_qty := v_prev;
  on_hand      := v_new;
  delta        := v_delta;
  SELECT p.name INTO product_name FROM wms.products p WHERE p.id = p_product_id;
  SELECT l.code INTO location_code FROM wms.locations l WHERE l.id = p_location_id;
  RETURN NEXT;
END $$;

-- ==========================================================================
-- Inbound -- receiving and put-away
-- ==========================================================================

CREATE OR REPLACE FUNCTION wms.receive_line(p_po_line_id bigint, p_qty integer, p_user_id bigint) RETURNS TABLE(po_line_id bigint, product_name text, received_qty integer, ordered_qty integer, on_hand integer, putaway_task_id bigint, po_complete boolean)
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_line      wms.purchase_order_lines%ROWTYPE;
  v_po        wms.purchase_orders%ROWTYPE;
  v_recv_loc  BIGINT;
  v_new_qty   INTEGER;
  v_task_id   BIGINT;
BEGIN
  IF p_qty <= 0 THEN
    RAISE EXCEPTION 'quantity must be positive, got %', p_qty
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT * INTO v_line FROM wms.purchase_order_lines l
    WHERE l.id = p_po_line_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown purchase order line %', p_po_line_id
      USING ERRCODE = 'no_data_found';
  END IF;

  -- Over-receipt backstop. The terminal already bound-checks against the open
  -- quantity, but that check lives in a Code node and this function is callable
  -- by anything -- an integration, a script, a future screen. The invariant
  -- "you cannot receive more than was ordered" belongs with the data, not with
  -- one caller. If a site genuinely accepts over-delivery, this is where a
  -- tolerance percentage would go; unbounded acceptance is not a policy.
  IF v_line.received_qty + p_qty > v_line.ordered_qty THEN
    RAISE EXCEPTION 'over-receipt on line %: % ordered, % already received, % attempted',
      v_line.id, v_line.ordered_qty, v_line.received_qty, p_qty
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT * INTO v_po FROM wms.purchase_orders po WHERE po.id = v_line.purchase_order_id;

  SELECT l.id INTO v_recv_loc FROM wms.locations l
   WHERE l.warehouse_id = v_po.warehouse_id AND l.kind = 'receiving' AND l.active
   ORDER BY l.id LIMIT 1;
  IF v_recv_loc IS NULL THEN
    RAISE EXCEPTION 'warehouse % has no active receiving location', v_po.warehouse_id;
  END IF;

  v_new_qty := wms.apply_movement(v_line.product_id, v_recv_loc, p_qty,
                                  'receipt', p_user_id, 'purchase_order_line', v_line.id);

  UPDATE wms.purchase_order_lines l
     SET received_qty = l.received_qty + p_qty
   WHERE l.id = v_line.id
   RETURNING l.received_qty INTO received_qty;

  INSERT INTO wms.putaway_tasks
    (product_id, from_location_id, suggested_location_id, qty)
  VALUES (v_line.product_id, v_recv_loc,
          wms.suggest_putaway_location(v_line.product_id, v_po.warehouse_id), p_qty)
  RETURNING id INTO v_task_id;

  UPDATE wms.purchase_orders po SET status = 'receiving'
   WHERE po.id = v_po.id AND po.status = 'open';

  po_line_id      := v_line.id;
  ordered_qty     := v_line.ordered_qty;
  on_hand         := v_new_qty;
  putaway_task_id := v_task_id;

  SELECT p.name INTO product_name FROM wms.products p WHERE p.id = v_line.product_id;

  SELECT bool_and(l.received_qty >= l.ordered_qty) INTO po_complete
    FROM wms.purchase_order_lines l WHERE l.purchase_order_id = v_po.id;

  RETURN NEXT;
END $$;

CREATE OR REPLACE FUNCTION wms.suggest_putaway_location(p_product_id bigint, p_warehouse_id bigint) RETURNS bigint
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE v_loc BIGINT;
BEGIN
  SELECT i.location_id INTO v_loc
    FROM wms.inventory i
    JOIN wms.locations l ON l.id = i.location_id
   WHERE i.product_id = p_product_id
     AND l.warehouse_id = p_warehouse_id
     AND l.kind = 'bin' AND l.active AND i.qty > 0
   ORDER BY l.pick_sequence NULLS LAST, l.id
   LIMIT 1;

  IF v_loc IS NOT NULL THEN
    RETURN v_loc;
  END IF;

  SELECT l.id INTO v_loc
    FROM wms.locations l
    LEFT JOIN wms.inventory i ON i.location_id = l.id AND i.qty > 0
   WHERE l.warehouse_id = p_warehouse_id AND l.kind = 'bin' AND l.active
     AND i.id IS NULL
   ORDER BY l.pick_sequence NULLS LAST, l.id
   LIMIT 1;

  RETURN v_loc;
END $$;

CREATE OR REPLACE FUNCTION wms.complete_putaway(p_task_id bigint, p_location_id bigint, p_user_id bigint) RETURNS TABLE(task_id bigint, product_name text, location_code text, on_hand integer)
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_task    wms.putaway_tasks%ROWTYPE;
  v_new_qty INTEGER;
BEGIN
  SELECT * INTO v_task FROM wms.putaway_tasks t WHERE t.id = p_task_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown put-away task %', p_task_id USING ERRCODE = 'no_data_found';
  END IF;
  IF v_task.status <> 'open' THEN
    RAISE EXCEPTION 'put-away task % is already %', p_task_id, v_task.status
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  PERFORM wms.apply_movement(v_task.product_id, v_task.from_location_id, -v_task.qty,
                             'putaway_out', p_user_id, 'putaway_task', v_task.id);
  v_new_qty := wms.apply_movement(v_task.product_id, p_location_id, v_task.qty,
                                  'putaway_in', p_user_id, 'putaway_task', v_task.id);

  UPDATE wms.putaway_tasks t
     SET status = 'done', to_location_id = p_location_id, completed_at = now()
   WHERE t.id = v_task.id;

  task_id := v_task.id;
  on_hand := v_new_qty;
  SELECT p.name INTO product_name FROM wms.products p WHERE p.id = v_task.product_id;
  SELECT l.code INTO location_code FROM wms.locations l WHERE l.id = p_location_id;
  RETURN NEXT;
END $$;

-- ==========================================================================
-- Outbound -- picking
-- ==========================================================================

CREATE OR REPLACE FUNCTION wms.claim_next_pick(p_user_id bigint) RETURNS TABLE(task_id bigint, product_id bigint, product_name text, sku text, location_id bigint, location_code text, qty integer, order_number text)
    LANGUAGE plpgsql
    AS $$
DECLARE v_task_id BIGINT;
BEGIN
  -- An operator who already has a task in progress gets that one back -- this
  -- is what makes "log back in after the battery died" resume correctly.
  SELECT t.id INTO v_task_id FROM wms.pick_tasks t
   WHERE t.assigned_user_id = p_user_id AND t.status = 'in_progress'
   ORDER BY t.id LIMIT 1;

  IF v_task_id IS NULL THEN
    SELECT t.id INTO v_task_id
      FROM wms.pick_tasks t
      JOIN wms.locations l ON l.id = t.location_id
     WHERE t.status = 'open'
     ORDER BY l.pick_sequence NULLS LAST, t.id
     FOR UPDATE OF t SKIP LOCKED
     LIMIT 1;

    IF v_task_id IS NULL THEN
      RETURN;
    END IF;

    UPDATE wms.pick_tasks t
       SET status = 'in_progress', assigned_user_id = p_user_id
     WHERE t.id = v_task_id;
  END IF;

  SELECT t.id, t.product_id, p.name, p.sku, t.location_id, l.code, t.qty, so.order_number
    INTO task_id, product_id, product_name, sku, location_id, location_code, qty, order_number
    FROM wms.pick_tasks t
    JOIN wms.products p ON p.id = t.product_id
    JOIN wms.locations l ON l.id = t.location_id
    JOIN wms.sales_order_lines sol ON sol.id = t.sales_order_line_id
    JOIN wms.sales_orders so ON so.id = sol.sales_order_id
   WHERE t.id = v_task_id;

  RETURN NEXT;
END $$;

CREATE OR REPLACE FUNCTION wms.confirm_pick(p_task_id bigint, p_qty integer, p_user_id bigint) RETURNS TABLE(task_id bigint, product_name text, picked_qty integer, requested_qty integer, remaining integer, on_hand integer, order_number text, order_complete boolean)
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_task    wms.pick_tasks%ROWTYPE;
  v_line    wms.sales_order_lines%ROWTYPE;
  v_new_qty INTEGER;
  v_so_id   BIGINT;
BEGIN
  IF p_qty < 0 THEN
    RAISE EXCEPTION 'quantity cannot be negative' USING ERRCODE = 'check_violation';
  END IF;

  SELECT * INTO v_task FROM wms.pick_tasks t WHERE t.id = p_task_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown pick task %', p_task_id USING ERRCODE = 'no_data_found';
  END IF;
  IF v_task.status NOT IN ('open', 'in_progress') THEN
    RAISE EXCEPTION 'pick task % is already %', p_task_id, v_task.status
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Over-pick backstop, for the same reason receive_line() has an over-receipt
  -- one: the terminal bound-checks, but the invariant belongs with the data.
  IF p_qty > v_task.qty THEN
    RAISE EXCEPTION 'over-pick on task %: % requested, % attempted',
      v_task.id, v_task.qty, p_qty
      USING ERRCODE = 'check_violation';
  END IF;

  IF p_qty > 0 THEN
    v_new_qty := wms.apply_movement(v_task.product_id, v_task.location_id, -p_qty,
                                    'pick', p_user_id, 'pick_task', v_task.id);
  ELSE
    SELECT COALESCE(i.qty, 0) INTO v_new_qty FROM wms.inventory i
     WHERE i.product_id = v_task.product_id AND i.location_id = v_task.location_id;
  END IF;

  UPDATE wms.pick_tasks t
     SET picked_qty = p_qty,
         status = CASE WHEN p_qty >= t.qty THEN 'done' ELSE 'short' END,
         completed_at = now()
   WHERE t.id = v_task.id;

  UPDATE wms.sales_order_lines sol
     SET picked_qty = sol.picked_qty + p_qty
   WHERE sol.id = v_task.sales_order_line_id
   RETURNING sol.sales_order_id INTO v_so_id;

  SELECT bool_and(sol.picked_qty >= sol.ordered_qty) INTO order_complete
    FROM wms.sales_order_lines sol WHERE sol.sales_order_id = v_so_id;

  IF order_complete THEN
    UPDATE wms.sales_orders so SET status = 'picked' WHERE so.id = v_so_id;
  ELSE
    UPDATE wms.sales_orders so SET status = 'picking'
     WHERE so.id = v_so_id AND so.status = 'open';
  END IF;

  task_id       := v_task.id;
  picked_qty    := p_qty;
  requested_qty := v_task.qty;
  remaining     := GREATEST(v_task.qty - p_qty, 0);
  on_hand       := v_new_qty;

  SELECT p.name INTO product_name FROM wms.products p WHERE p.id = v_task.product_id;
  SELECT so.order_number INTO order_number FROM wms.sales_orders so WHERE so.id = v_so_id;
  RETURN NEXT;
END $$;
