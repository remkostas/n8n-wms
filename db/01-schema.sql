-- n8n-wms: data model.
--
-- Everything lives in the `wms` schema so the system can share a database with
-- other applications without colliding. No extensions are required: session
-- tokens come from core gen_random_uuid() (PostgreSQL 13+), not pgcrypto.
--
-- Two rules shape this model:
--
--   1. inventory_transactions is the ledger; inventory is the running balance.
--      Every movement writes both, inside one plpgsql call (see
--      02-functions.sql), because n8n cannot hold a transaction open across
--      nodes. SUM(delta) per product/location must always equal inventory.qty.
--
--   2. Anything an operator can scan has a row in barcode_mappings, so one
--      lookup tells the state machine what was scanned: an article, a shelf, a
--      badge or an order.

CREATE SCHEMA wms;

-- ------------------------------------------------------------ master data

CREATE TABLE wms.warehouses (
    id          bigserial PRIMARY KEY,
    code        text NOT NULL UNIQUE,
    name        text NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- Docks and staging areas are locations too, not special cases: received goods
-- sit on DOCK-IN as real, queryable stock until they are put away.
CREATE TABLE wms.locations (
    id             bigserial PRIMARY KEY,
    warehouse_id   bigint NOT NULL REFERENCES wms.warehouses(id),
    code           text NOT NULL,
    kind           text NOT NULL DEFAULT 'bin'
                   CHECK (kind IN ('receiving', 'bin', 'staging', 'shipping')),
    -- Walking order through the warehouse; picks are claimed in this order.
    pick_sequence  integer,
    active         boolean NOT NULL DEFAULT true,
    UNIQUE (warehouse_id, code)
);

CREATE TABLE wms.products (
    id            bigserial PRIMARY KEY,
    sku           text NOT NULL UNIQUE,
    name          text NOT NULL,
    description   text,
    uom           text NOT NULL DEFAULT 'pcs',
    weight_grams  integer,
    active        boolean NOT NULL DEFAULT true,
    created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE wms.users (
    id          bigserial PRIMARY KEY,
    badge_code  text NOT NULL UNIQUE,
    name        text NOT NULL,
    -- Stored, not yet enforced: no supervisor-only screens exist.
    role        text NOT NULL DEFAULT 'operator'
                CHECK (role IN ('operator', 'supervisor', 'admin')),
    active      boolean NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE wms.barcode_mappings (
    barcode      text PRIMARY KEY,
    entity_type  text NOT NULL
                 CHECK (entity_type IN ('product', 'location', 'user', 'purchase_order', 'sales_order')),
    entity_id    bigint NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now()
);

-- ------------------------------------------------------------ stock

CREATE TABLE wms.inventory (
    id           bigserial PRIMARY KEY,
    product_id   bigint NOT NULL REFERENCES wms.products(id),
    location_id  bigint NOT NULL REFERENCES wms.locations(id),
    -- A movement that would take stock negative is refused here rather than
    -- recorded as an impossible level.
    qty          integer NOT NULL DEFAULT 0 CHECK (qty >= 0),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (product_id, location_id)
);

CREATE INDEX inventory_product_idx  ON wms.inventory (product_id);
CREATE INDEX inventory_location_idx ON wms.inventory (location_id);

-- Append-only. reference_type/reference_id point at whatever caused the
-- movement (a purchase-order line, a pick task, a put-away task).
CREATE TABLE wms.inventory_transactions (
    id              bigserial PRIMARY KEY,
    product_id      bigint NOT NULL REFERENCES wms.products(id),
    location_id     bigint NOT NULL REFERENCES wms.locations(id),
    delta           integer NOT NULL,
    reason          text NOT NULL
                    CHECK (reason IN ('receipt', 'putaway_out', 'putaway_in', 'pick', 'ship', 'adjustment', 'count')),
    user_id         bigint REFERENCES wms.users(id),
    reference_type  text,
    reference_id    bigint,
    occurred_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX txn_product_time_idx ON wms.inventory_transactions (product_id, occurred_at DESC);
CREATE INDEX txn_reference_idx    ON wms.inventory_transactions (reference_type, reference_id);

-- ------------------------------------------------------------ inbound

CREATE TABLE wms.purchase_orders (
    id            bigserial PRIMARY KEY,
    order_number  text NOT NULL UNIQUE,
    vendor        text NOT NULL,
    warehouse_id  bigint NOT NULL REFERENCES wms.warehouses(id),
    status        text NOT NULL DEFAULT 'open'
                  CHECK (status IN ('open', 'receiving', 'closed', 'cancelled')),
    expected_at   date,
    created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE wms.purchase_order_lines (
    id                 bigserial PRIMARY KEY,
    purchase_order_id  bigint NOT NULL REFERENCES wms.purchase_orders(id),
    line_number        integer NOT NULL,
    product_id         bigint NOT NULL REFERENCES wms.products(id),
    ordered_qty        integer NOT NULL CHECK (ordered_qty > 0),
    received_qty       integer NOT NULL DEFAULT 0 CHECK (received_qty >= 0),
    UNIQUE (purchase_order_id, line_number)
);

CREATE INDEX po_lines_order_idx ON wms.purchase_order_lines (purchase_order_id);

-- Created by wms.receive_line(): goods land on the dock, and a task says where
-- they should go next.
CREATE TABLE wms.putaway_tasks (
    id                     bigserial PRIMARY KEY,
    product_id             bigint NOT NULL REFERENCES wms.products(id),
    from_location_id       bigint NOT NULL REFERENCES wms.locations(id),
    suggested_location_id  bigint REFERENCES wms.locations(id),
    to_location_id         bigint REFERENCES wms.locations(id),
    qty                    integer NOT NULL CHECK (qty > 0),
    status                 text NOT NULL DEFAULT 'open'
                           CHECK (status IN ('open', 'done', 'cancelled')),
    created_at             timestamptz NOT NULL DEFAULT now(),
    completed_at           timestamptz
);

-- ------------------------------------------------------------ outbound

CREATE TABLE wms.sales_orders (
    id            bigserial PRIMARY KEY,
    order_number  text NOT NULL UNIQUE,
    customer      text NOT NULL,
    warehouse_id  bigint NOT NULL REFERENCES wms.warehouses(id),
    status        text NOT NULL DEFAULT 'open'
                  CHECK (status IN ('open', 'picking', 'picked', 'packed', 'shipped', 'cancelled')),
    created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE wms.sales_order_lines (
    id              bigserial PRIMARY KEY,
    sales_order_id  bigint NOT NULL REFERENCES wms.sales_orders(id),
    line_number     integer NOT NULL,
    product_id      bigint NOT NULL REFERENCES wms.products(id),
    ordered_qty     integer NOT NULL CHECK (ordered_qty > 0),
    picked_qty      integer NOT NULL DEFAULT 0 CHECK (picked_qty >= 0),
    UNIQUE (sales_order_id, line_number)
);

CREATE INDEX so_lines_order_idx ON wms.sales_order_lines (sales_order_id);

-- 'short' is a real outcome, not an error: an operator who finds 8 where 10
-- were expected records 8, and the order shows what is still owed.
CREATE TABLE wms.pick_tasks (
    id                   bigserial PRIMARY KEY,
    sales_order_line_id  bigint NOT NULL REFERENCES wms.sales_order_lines(id),
    product_id           bigint NOT NULL REFERENCES wms.products(id),
    location_id          bigint NOT NULL REFERENCES wms.locations(id),
    qty                  integer NOT NULL CHECK (qty > 0),
    picked_qty           integer NOT NULL DEFAULT 0 CHECK (picked_qty >= 0),
    status               text NOT NULL DEFAULT 'open'
                         CHECK (status IN ('open', 'in_progress', 'done', 'short', 'cancelled')),
    assigned_user_id     bigint REFERENCES wms.users(id),
    created_at           timestamptz NOT NULL DEFAULT now(),
    completed_at         timestamptz
);

CREATE INDEX pick_tasks_open_idx ON wms.pick_tasks (status, assigned_user_id);

-- ------------------------------------------------------------ terminal sessions

-- n8n has no session primitive, so the terminal's state machine lives here:
-- which screen an operator is on and what they have scanned so far. Keeping it
-- in the database rather than in n8n's execution data is what lets a
-- half-finished task survive a page refresh or a switch to another device.
CREATE TABLE wms.operator_sessions (
    token         text PRIMARY KEY,
    user_id       bigint NOT NULL REFERENCES wms.users(id),
    state         text NOT NULL DEFAULT 'idle',
    context       jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at    timestamptz NOT NULL DEFAULT now(),
    last_seen_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX operator_sessions_user_idx ON wms.operator_sessions (user_id);

-- Reserved for per-scan telemetry; the PoC measured latency externally instead
-- (bench/bench.py), so nothing writes here yet.
CREATE TABLE wms.scan_events (
    id             bigserial PRIMARY KEY,
    session_token  text,
    user_id        bigint REFERENCES wms.users(id),
    screen         text NOT NULL,
    scanned        text,
    resolved_type  text,
    outcome        text NOT NULL,
    duration_ms    integer,
    occurred_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX scan_events_time_idx ON wms.scan_events (occurred_at DESC);

-- ------------------------------------------------------------ views

CREATE VIEW wms.open_receipt_lines AS
SELECT po.id AS purchase_order_id,
       po.order_number,
       po.vendor,
       l.id AS po_line_id,
       l.line_number,
       p.id AS product_id,
       p.sku,
       p.name AS product_name,
       l.ordered_qty,
       l.received_qty,
       l.ordered_qty - l.received_qty AS open_qty
  FROM wms.purchase_order_lines l
  JOIN wms.purchase_orders po ON po.id = l.purchase_order_id
  JOIN wms.products p         ON p.id = l.product_id
 WHERE po.status IN ('open', 'receiving')
   AND l.received_qty < l.ordered_qty;

CREATE VIEW wms.stock_on_hand AS
SELECT p.id AS product_id,
       p.sku,
       p.name AS product_name,
       l.id AS location_id,
       l.code AS location_code,
       l.kind AS location_kind,
       w.code AS warehouse_code,
       i.qty,
       i.updated_at
  FROM wms.inventory i
  JOIN wms.products p   ON p.id = i.product_id
  JOIN wms.locations l  ON l.id = i.location_id
  JOIN wms.warehouses w ON w.id = l.warehouse_id
 WHERE i.qty > 0;
