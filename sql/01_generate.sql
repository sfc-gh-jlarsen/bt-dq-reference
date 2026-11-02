-- 01_generate.sql
-- Deterministic synthetic loads. No customer data.
--
-- Each batch is one multi-statement transaction:
--   BEGIN; counter update; data change; ledger insert; COMMIT;
-- The ledger insert is inside that transaction, including the empty batch.
--
-- snow sql stops the file when a statement fails and does not run the rest,
-- including COMMIT. A failed statement does not undo earlier statements in
-- the same BEGIN block. ROLLBACK is first, before each BEGIN, so a rerun
-- after a stop clears the open transaction instead of leaving a partial batch.
-- Do not remove those ROLLBACK lines.
--
-- 03_prove.sql repeats this shape. Keep the two copies aligned.
--
-- load_ts is not part of the duplicate key.
-- Keys are (order_id, line_no). line_no cycles 1..5 so a row's order_id
-- repeats inside one good batch. A one-column DUPLICATE_COUNT(order_id)
-- is therefore not the same check as the pair. The pair is proved separately.

-- Target names come from config/target.sql ($demo_db, $demo_schema).
-- Run that file first in the same session. Do not hardcode the database here.

USE ROLE BT_BUILDER_ROLE;
USE WAREHOUSE BT_WH;
USE DATABASE IDENTIFIER($demo_db);
USE SCHEMA IDENTIFIER($demo_schema);

-- Reset. Does not consume a batch id.
-- The counter restarts at 0. Ids are monotonic within a run, not across runs.
ROLLBACK;
BEGIN;
DELETE FROM bt_orders;
DELETE FROM bt_load_ledger;
UPDATE bt_batch_id SET id = 0;
COMMIT;

-- good: 1000 rows, keys (order 1..200) x (line 1..5).
ROLLBACK;
BEGIN;
UPDATE bt_batch_id SET id = id + 1;
DELETE FROM bt_orders;
INSERT INTO bt_orders (order_id, line_no, sku, qty, load_ts, batch_id)
SELECT
  FLOOR((ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1) / 5) + 1,
  MOD(ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, 5) + 1,
  'SKU-' || LPAD(TO_VARCHAR(FLOOR((ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1) / 5) + 1), 6, '0'),
  1,
  CURRENT_TIMESTAMP(),
  (SELECT id FROM bt_batch_id)
FROM TABLE(GENERATOR(ROWCOUNT => 1000));
INSERT INTO bt_load_ledger (batch_id, batch_name, attempted_at, row_count, note)
SELECT id, 'good', CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 1000, 'synthetic load'
FROM bt_batch_id;
COMMIT;

-- duplicate_replay: same keys, later load_ts. Run after good, before empty.
ROLLBACK;
BEGIN;
UPDATE bt_batch_id SET id = id + 1;
INSERT INTO bt_orders (order_id, line_no, sku, qty, load_ts, batch_id)
SELECT
  order_id,
  line_no,
  sku,
  qty,
  DATEADD('minute', 5, CURRENT_TIMESTAMP()),
  (SELECT id FROM bt_batch_id)
FROM bt_orders
WHERE batch_id = (SELECT MIN(batch_id) FROM bt_orders);
INSERT INTO bt_load_ledger (batch_id, batch_name, attempted_at, row_count, note)
SELECT id, 'duplicate_replay', CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 1000, 'synthetic load'
FROM bt_batch_id;
COMMIT;

-- empty: delete the table, still write a ledger row.
ROLLBACK;
BEGIN;
UPDATE bt_batch_id SET id = id + 1;
DELETE FROM bt_orders;
INSERT INTO bt_load_ledger (batch_id, batch_name, attempted_at, row_count, note)
SELECT id, 'empty', CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 0, 'synthetic load'
FROM bt_batch_id;
COMMIT;

-- spike: 10000 rows, replaces the table. Same 5-line key shape.
ROLLBACK;
BEGIN;
UPDATE bt_batch_id SET id = id + 1;
DELETE FROM bt_orders;
INSERT INTO bt_orders (order_id, line_no, sku, qty, load_ts, batch_id)
SELECT
  FLOOR((ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1) / 5) + 1,
  MOD(ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, 5) + 1,
  'SKU-' || LPAD(TO_VARCHAR(FLOOR((ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1) / 5) + 1), 6, '0'),
  1,
  CURRENT_TIMESTAMP(),
  (SELECT id FROM bt_batch_id)
FROM TABLE(GENERATOR(ROWCOUNT => 10000));
INSERT INTO bt_load_ledger (batch_id, batch_name, attempted_at, row_count, note)
SELECT id, 'spike', CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 10000, 'synthetic load'
FROM bt_batch_id;
COMMIT;
