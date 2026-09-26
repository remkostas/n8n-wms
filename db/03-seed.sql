-- n8n-wms: demo data. One small electrical-parts warehouse, one inbound and one
-- outbound order, set up so the interesting cases are all reachable:
--
--   * PO-1042 line 1 is already fully received, so it must NOT be offered.
--   * SO-2075's third pick asks for 10 DIN rails where only 8 are on the shelf:
--     the deliberate short pick.
--   * Two articles (SKU-1011, SKU-1012) have no stock anywhere yet.
--
-- All names and companies are fictional. docs/TEST-CASES.md walks through
-- every scenario against exactly this state.
--
-- IDs are explicit so barcode_mappings can point at them; the sequences are
-- moved past them at the end.

INSERT INTO wms.warehouses (id, code, name) VALUES
  (1, 'WH-01', 'Demo warehouse');

INSERT INTO wms.locations (id, warehouse_id, code, kind, pick_sequence) VALUES
  ( 1, 1, 'DOCK-IN',  'receiving', NULL),
  ( 2, 1, 'STAGE-01', 'staging',   NULL),
  ( 3, 1, 'DOCK-OUT', 'shipping',  NULL),
  ( 4, 1, 'A-01-1',   'bin',  10),
  ( 5, 1, 'A-01-2',   'bin',  20),
  ( 6, 1, 'A-02-1',   'bin',  30),
  ( 7, 1, 'A-02-2',   'bin',  40),
  ( 8, 1, 'B-01-1',   'bin',  50),
  ( 9, 1, 'B-01-2',   'bin',  60),
  (10, 1, 'B-02-1',   'bin',  70),
  (11, 1, 'B-02-2',   'bin',  80),
  (12, 1, 'C-01-1',   'bin',  90),
  (13, 1, 'C-01-2',   'bin', 100);

INSERT INTO wms.products (id, sku, name, description, uom, weight_grams) VALUES
  ( 1, 'SKU-1001', 'Hex bolt M8x40',       'Zinc-plated, box of 100', 'box', 1200),
  ( 2, 'SKU-1002', 'Hex nut M8',           'Zinc-plated, box of 200', 'box',  900),
  ( 3, 'SKU-1003', 'Washer M8',            'Box of 500',              'box',  700),
  ( 4, 'SKU-1004', 'Cable tie 200mm',      'Black, bag of 100',       'bag',  180),
  ( 5, 'SKU-1005', 'Cable tie 300mm',      'Black, bag of 100',       'bag',  260),
  ( 6, 'SKU-1006', 'Insulation tape 19mm', 'Roll, 20m',               'pcs',   90),
  ( 7, 'SKU-1007', 'Wire ferrule 1.5mm',   'Bag of 1000',             'bag',  400),
  ( 8, 'SKU-1008', 'Terminal block 6-way', 'DIN rail mount',          'pcs',  150),
  ( 9, 'SKU-1009', 'DIN rail 35mm',        'Length 1m',               'pcs',  480),
  (10, 'SKU-1010', 'Cable gland M20',      'IP68, bag of 25',         'bag',  320),
  (11, 'SKU-1011', 'Heat shrink 6mm',      'Assorted, box',           'box',  210),
  (12, 'SKU-1012', 'Junction box IP65',    '100x100x50mm',            'pcs',  340);

INSERT INTO wms.users (id, badge_code, name, role) VALUES
  (1, 'BADGE-1001', 'Marijke Bakker', 'operator'),
  (2, 'BADGE-1002', 'Tom de Vries',   'operator'),
  (3, 'BADGE-1003', 'Sara Yilmaz',    'supervisor');

-- Product barcodes are EAN-13-shaped; shelves scan as LOC-<code>.
INSERT INTO wms.barcode_mappings (barcode, entity_type, entity_id)
SELECT '40000000010' || lpad(id::text, 2, '0'), 'product', id FROM wms.products
UNION ALL
SELECT 'LOC-' || code, 'location', id FROM wms.locations
UNION ALL
SELECT badge_code, 'user', id FROM wms.users;

-- Opening stock. Each balance gets a matching ledger row, so the invariant
-- "ledger sum = on-hand" holds from the very first moment.
INSERT INTO wms.inventory (product_id, location_id, qty) VALUES
  ( 1,  4,  48),
  ( 2,  5, 120),
  ( 3,  6,  90),
  ( 4,  7,  36),
  ( 5,  8,  24),
  ( 6,  9,  75),
  ( 7, 10,  12),
  ( 8, 11,  60),
  ( 9, 12,   8),
  (10, 13,  44);

INSERT INTO wms.inventory_transactions (product_id, location_id, delta, reason, reference_type)
SELECT product_id, location_id, qty, 'count', 'opening_balance' FROM wms.inventory;

-- Inbound.
INSERT INTO wms.purchase_orders (id, order_number, vendor, warehouse_id, status, expected_at) VALUES
  (1, 'PO-1042', 'Vendor 30021', 1, 'receiving', CURRENT_DATE);

INSERT INTO wms.purchase_order_lines (purchase_order_id, line_number, product_id, ordered_qty, received_qty) VALUES
  (1, 1,  1,  60, 60),   -- already fully received: must not be offered
  (1, 2,  4, 120,  0),
  (1, 3,  7, 200,  0),
  (1, 4, 11,  48,  0),
  (1, 5, 12,  30,  0);

INSERT INTO wms.barcode_mappings (barcode, entity_type, entity_id) VALUES
  ('PO-1042', 'purchase_order', 1);

-- Outbound.
INSERT INTO wms.sales_orders (id, order_number, customer, warehouse_id, status) VALUES
  (1, 'SO-2075', 'Musterfirma Elektro GmbH', 1, 'open');

INSERT INTO wms.sales_order_lines (id, sales_order_id, line_number, product_id, ordered_qty) VALUES
  (1, 1, 1, 2, 20),
  (2, 1, 2, 6, 15),
  (3, 1, 3, 9, 10);

INSERT INTO wms.pick_tasks (sales_order_line_id, product_id, location_id, qty) VALUES
  (1, 2,  5, 20),
  (2, 6,  9, 15),
  (3, 9, 12, 10);        -- only 8 on the shelf: the short pick

INSERT INTO wms.barcode_mappings (barcode, entity_type, entity_id) VALUES
  ('SO-2075', 'sales_order', 1);

SELECT setval('wms.warehouses_id_seq',         (SELECT max(id) FROM wms.warehouses));
SELECT setval('wms.locations_id_seq',          (SELECT max(id) FROM wms.locations));
SELECT setval('wms.products_id_seq',           (SELECT max(id) FROM wms.products));
SELECT setval('wms.users_id_seq',              (SELECT max(id) FROM wms.users));
SELECT setval('wms.purchase_orders_id_seq',    (SELECT max(id) FROM wms.purchase_orders));
SELECT setval('wms.sales_orders_id_seq',       (SELECT max(id) FROM wms.sales_orders));
SELECT setval('wms.sales_order_lines_id_seq',  (SELECT max(id) FROM wms.sales_order_lines));
