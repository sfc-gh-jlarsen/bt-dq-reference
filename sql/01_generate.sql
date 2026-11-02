-- 01_generate.sql
-- Deterministic synthetic loads. No customer data.
-- No stored procedures: BT_BUILDER_ROLE has CREATE TABLE and CREATE VIEW on
-- the assigned schema, not CREATE PROCEDURE.
--
-- Each batch is a separate transaction (BEGIN/COMMIT). The ledger insert is
-- in that same transaction, including the empty batch.
--
-- These statements are the generator. 03_prove.sql repeats the ones it needs
-- so the proof file runs on its own after 00 and 02. Keep the two copies
-- the same shape: counter update, data change, ledger insert, commit.
--
-- load_ts is not part of the duplicate key.

-- Target names come from config/target.sql ($demo_db, $demo_schema).
-- Run that file first in the same session. Do not hardcode the database here.

USE ROLE BT_BUILDER_ROLE;
USE WAREHOUSE BT_WH;
USE DATABASE IDENTIFIER($demo_db);
USE SCHEMA IDENTIFIER($demo_schema);

-- Reset. Does not consume a batch id.
BEGIN;
DELETE FROM bt_orders;
DELETE FROM bt_load_ledger;
UPDATE bt_batch_id SET id = 0;
COMMIT;

-- good: 1000 rows, keys (1..1000, 1).
BEGIN;
UPDATE bt_batch_id SET id = id + 1;
DELETE FROM bt_orders;
INSERT INTO bt_orders (order_id, line_no, sku, qty, load_ts, batch_id)
SELECT
  SEQ4() + 1,
  1,
  'SKU-' || LPAD((SEQ4() + 1)::VARCHAR, 6, '0'),
  1,
  CURRENT_TIMESTAMP(),
  (SELECT id FROM bt_batch_id)
FROM TABLE(GENERATOR(ROWCOUNT => 1000));
INSERT INTO bt_load_ledger (batch_id, batch_name, attempted_at, row_count, note)
SELECT id, 'good', CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 1000, 'synthetic load'
FROM bt_batch_id;
COMMIT;

-- duplicate_replay: same keys, later load_ts. Run after good, before empty.
BEGIN;
UPDATE bt_batch_id SET id = id + 1;
INSERT INTO bt_orders (order_id, line_no, sku, qty, load_ts, batch_id)
SELECT
  order_id,
  line_no,
  sku,
  qty,
  DATEADD('minute', 5, CURRENT_TIMESTAMP())::TIMESTAMP_NTZ,
  (SELECT id FROM bt_batch_id)
FROM bt_orders
WHERE batch_id = (SELECT MIN(batch_id) FROM bt_orders);
INSERT INTO bt_load_ledger (batch_id, batch_name, attempted_at, row_count, note)
SELECT id, 'duplicate_replay', CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 1000, 'synthetic load'
FROM bt_batch_id;
COMMIT;

-- empty: delete the table, still write a ledger row.
BEGIN;
UPDATE bt_batch_id SET id = id + 1;
DELETE FROM bt_orders;
INSERT INTO bt_load_ledger (batch_id, batch_name, attempted_at, row_count, note)
SELECT id, 'empty', CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 0, 'synthetic load'
FROM bt_batch_id;
COMMIT;

-- spike: 10000 rows, replaces the table.
BEGIN;
UPDATE bt_batch_id SET id = id + 1;
DELETE FROM bt_orders;
INSERT INTO bt_orders (order_id, line_no, sku, qty, load_ts, batch_id)
SELECT
  SEQ4() + 1,
  1,
  'SKU-' || LPAD((SEQ4() + 1)::VARCHAR, 6, '0'),
  1,
  CURRENT_TIMESTAMP(),
  (SELECT id FROM bt_batch_id)
FROM TABLE(GENERATOR(ROWCOUNT => 10000));
INSERT INTO bt_load_ledger (batch_id, batch_name, attempted_at, row_count, note)
SELECT id, 'spike', CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 10000, 'synthetic load'
FROM bt_batch_id;
COMMIT;
