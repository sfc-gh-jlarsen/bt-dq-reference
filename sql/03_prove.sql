-- 03_prove.sql
-- Manual proof. Resettable. Does not read DATA_QUALITY_MONITORING_RESULTS
-- and does not wait for a schedule.
--
-- Docs checked 2026-11-02:
--   https://docs.snowflake.com/en/sql-reference/functions/dmf_duplicate_count
--   A direct DUPLICATE_COUNT call must project exactly one column. More than
--   one column is an association, or SYSTEM$DATA_METRIC_SCAN, which returns
--   the failing rows (not the scalar). A computed VARCHAR is not a legal
--   direct argument (DUPLICATE_COUNT$V1 rejects VARCHAR(134217728)).
--   https://docs.snowflake.com/en/sql-reference/functions/system_data_metric_scan
--   SYSTEM$DATA_METRIC_SCAN supports DUPLICATE_COUNT and multiple columns.
--   It does not support ROW_COUNT, and it returns rows rather than VALUE.
--   ROW_COUNT cannot be called directly. The row-count check is COUNT(*)
--   on the latest-batch view, the set the scheduled DMF reads.
--   FRESHNESS direct call accepts DATE, TIMESTAMP_LTZ, TIMESTAMP_TZ.
--   TIMESTAMP_NTZ is rejected, so load_ts is TIMESTAMP_LTZ.
--
-- Keys are (order_id, line_no). line_no is 1..5, so order_id repeats inside
-- a good batch. DUPLICATE_COUNT(order_id) is not a stand-in for the pair.
-- The pair metric is the row count from SYSTEM$DATA_METRIC_SCAN on
-- (order_id, line_no). That is the DMF, not a grouped SQL stand-in.
--
-- snow sql stops the file when a statement fails and does not run COMMIT.
-- ROLLBACK before each BEGIN clears a partial batch left by that stop.
--
-- PASS means the expectation held. FAIL means a bad batch was outside the
-- threshold. Labels are not flipped.

-- Target names come from config/target.sql ($demo_db, $demo_schema).
-- Run that file first in the same session. Do not hardcode the database here.

USE ROLE BT_BUILDER_ROLE;
USE WAREHOUSE BT_WH;
USE DATABASE IDENTIFIER($demo_db);
USE SCHEMA IDENTIFIER($demo_schema);

CREATE OR REPLACE TEMPORARY TABLE bt_proof (
  check_name   VARCHAR,
  failure_mode VARCHAR,
  script       VARCHAR,
  metric       VARCHAR,
  observed     NUMBER(38, 0),
  threshold    VARCHAR,
  result       VARCHAR
);

-- Reset. Counter is monotonic within this run, then starts over.
ROLLBACK;
BEGIN;
DELETE FROM bt_orders;
DELETE FROM bt_load_ledger;
UPDATE bt_batch_id SET id = 0;
COMMIT;

-- --- good batch -----------------------------------------------------------
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

INSERT INTO bt_proof
SELECT
  'duplicate_keys_order_id',
  'none (good batch). order_id repeats because each order has lines 1..5',
  'good batch in 03_prove.sql',
  'DUPLICATE_COUNT(order_id) direct call. Not the pair check.',
  SNOWFLAKE.CORE.DUPLICATE_COUNT(SELECT order_id FROM bt_orders),
  'VALUE = 0 is the pair expectation, not this column',
  IFF(
    SNOWFLAKE.CORE.DUPLICATE_COUNT(SELECT order_id FROM bt_orders) = 0,
    'PASS', 'FAIL');

INSERT INTO bt_proof
SELECT
  'duplicate_keys_pair',
  'none (good batch, unique (order_id, line_no))',
  'good batch in 03_prove.sql',
  'SYSTEM$DATA_METRIC_SCAN DUPLICATE_COUNT on (order_id, line_no), row count',
  (SELECT COUNT(*) FROM TABLE(SYSTEM$DATA_METRIC_SCAN(
      REF_ENTITY_NAME => 'bt_orders',
      METRIC_NAME => 'SNOWFLAKE.CORE.DUPLICATE_COUNT',
      ARGUMENT_NAME => 'order_id, line_no'))),
  'VALUE = 0',
  IFF(
    (SELECT COUNT(*) FROM TABLE(SYSTEM$DATA_METRIC_SCAN(
        REF_ENTITY_NAME => 'bt_orders',
        METRIC_NAME => 'SNOWFLAKE.CORE.DUPLICATE_COUNT',
        ARGUMENT_NAME => 'order_id, line_no'))) = 0,
    'PASS', 'FAIL');

INSERT INTO bt_proof
SELECT
  'latest_batch_rowcount',
  'none (good batch, 1000 rows)',
  'good batch in 03_prove.sql',
  'ROW_COUNT on bt_orders_latest_batch (COUNT of the view)',
  (SELECT COUNT(*) FROM bt_orders_latest_batch),
  '800 <= VALUE AND VALUE <= 1200',
  IFF(
    (SELECT COUNT(*) FROM bt_orders_latest_batch) >= 800
      AND (SELECT COUNT(*) FROM bt_orders_latest_batch) <= 1200,
    'PASS', 'FAIL');

INSERT INTO bt_proof
SELECT
  'freshness',
  'none (load_ts is the insert timestamp)',
  'good batch in 03_prove.sql',
  'FRESHNESS(load_ts) direct call',
  SNOWFLAKE.CORE.FRESHNESS(SELECT load_ts FROM bt_orders_latest_freshness),
  'VALUE < 900',
  IFF(
    SNOWFLAKE.CORE.FRESHNESS(SELECT load_ts FROM bt_orders_latest_freshness) < 900,
    'PASS', 'FAIL');

-- --- duplicate replay -----------------------------------------------------
ROLLBACK;
BEGIN;
UPDATE bt_batch_id SET id = id + 1;
INSERT INTO bt_orders (order_id, line_no, sku, qty, load_ts, batch_id)
SELECT order_id, line_no, sku, qty,
       DATEADD('minute', 5, CURRENT_TIMESTAMP()),
       (SELECT id FROM bt_batch_id)
FROM bt_orders
WHERE batch_id = (SELECT MIN(batch_id) FROM bt_orders);
INSERT INTO bt_load_ledger (batch_id, batch_name, attempted_at, row_count, note)
SELECT id, 'duplicate_replay', CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 1000, 'synthetic load'
FROM bt_batch_id;
COMMIT;

INSERT INTO bt_proof
SELECT
  'duplicate_keys_order_id',
  'same keys inserted again. This column still is not the pair.',
  'duplicate_replay batch in 03_prove.sql',
  'DUPLICATE_COUNT(order_id) direct call. Not the pair check.',
  SNOWFLAKE.CORE.DUPLICATE_COUNT(SELECT order_id FROM bt_orders),
  'VALUE = 0 is the pair expectation, not this column',
  IFF(
    SNOWFLAKE.CORE.DUPLICATE_COUNT(SELECT order_id FROM bt_orders) = 0,
    'PASS', 'FAIL');

INSERT INTO bt_proof
SELECT
  'duplicate_keys_pair',
  'same (order_id, line_no) inserted again with a new load_ts',
  'duplicate_replay batch in 03_prove.sql',
  'SYSTEM$DATA_METRIC_SCAN DUPLICATE_COUNT on (order_id, line_no), row count',
  (SELECT COUNT(*) FROM TABLE(SYSTEM$DATA_METRIC_SCAN(
      REF_ENTITY_NAME => 'bt_orders',
      METRIC_NAME => 'SNOWFLAKE.CORE.DUPLICATE_COUNT',
      ARGUMENT_NAME => 'order_id, line_no'))),
  'VALUE = 0',
  IFF(
    (SELECT COUNT(*) FROM TABLE(SYSTEM$DATA_METRIC_SCAN(
        REF_ENTITY_NAME => 'bt_orders',
        METRIC_NAME => 'SNOWFLAKE.CORE.DUPLICATE_COUNT',
        ARGUMENT_NAME => 'order_id, line_no'))) = 0,
    'PASS', 'FAIL');

-- --- empty attempt --------------------------------------------------------
ROLLBACK;
BEGIN;
UPDATE bt_batch_id SET id = id + 1;
DELETE FROM bt_orders;
INSERT INTO bt_load_ledger (batch_id, batch_name, attempted_at, row_count, note)
SELECT id, 'empty', CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 0, 'synthetic load'
FROM bt_batch_id;
COMMIT;

INSERT INTO bt_proof
SELECT
  'latest_batch_rowcount',
  'empty load deletes the table; ledger still records the attempt',
  'empty batch in 03_prove.sql',
  'ROW_COUNT on bt_orders_latest_batch (COUNT of the view)',
  (SELECT COUNT(*) FROM bt_orders_latest_batch),
  '800 <= VALUE AND VALUE <= 1200',
  IFF(
    (SELECT COUNT(*) FROM bt_orders_latest_batch) >= 800
      AND (SELECT COUNT(*) FROM bt_orders_latest_batch) <= 1200,
    'PASS', 'FAIL');

-- --- spike ----------------------------------------------------------------
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

INSERT INTO bt_proof
SELECT
  'latest_batch_rowcount',
  'bounded spike, 10000 rows',
  'spike batch in 03_prove.sql',
  'ROW_COUNT on bt_orders_latest_batch (COUNT of the view)',
  (SELECT COUNT(*) FROM bt_orders_latest_batch),
  '800 <= VALUE AND VALUE <= 1200',
  IFF(
    (SELECT COUNT(*) FROM bt_orders_latest_batch) >= 800
      AND (SELECT COUNT(*) FROM bt_orders_latest_batch) <= 1200,
    'PASS', 'FAIL');

-- --- stale timestamp, no wait ---------------------------------------------
-- New good-sized batch so freshness is not measured on the empty table.
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
  DATEADD('second', -3600, CURRENT_TIMESTAMP()),
  (SELECT id FROM bt_batch_id)
FROM TABLE(GENERATOR(ROWCOUNT => 1000));
INSERT INTO bt_load_ledger (batch_id, batch_name, attempted_at, row_count, note)
SELECT id, 'stale_fixture', CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 1000,
       'load_ts written 3600 seconds old; not a wait'
FROM bt_batch_id;
COMMIT;

INSERT INTO bt_proof
SELECT
  'freshness',
  'load_ts inserted 3600 seconds in the past',
  'stale_fixture batch in 03_prove.sql',
  'FRESHNESS(load_ts) direct call',
  SNOWFLAKE.CORE.FRESHNESS(SELECT load_ts FROM bt_orders_latest_freshness),
  'VALUE < 900',
  IFF(
    SNOWFLAKE.CORE.FRESHNESS(SELECT load_ts FROM bt_orders_latest_freshness) < 900,
    'PASS', 'FAIL');

SELECT check_name, failure_mode, script, metric, observed, threshold, result
FROM bt_proof
ORDER BY check_name, failure_mode;

SELECT batch_id, batch_name, row_count
FROM bt_load_ledger
ORDER BY batch_id;
