-- 00_setup.sql
-- Customer-neutral data-quality reference.
-- Creates objects in the schema the caller has already selected.
-- Does not CREATE DATABASE, CREATE WAREHOUSE, or change a resource monitor.
--
-- Required session before this file: config/target.sql, which sets
-- $demo_db and $demo_schema. This file uses those variables.
--
-- Docs checked 2026-11-02:
--   https://docs.snowflake.com/en/user-guide/data-quality-working
--   https://docs.snowflake.com/en/user-guide/data-quality-expectations
--   https://docs.snowflake.com/en/sql-reference/functions/dmf_duplicate_count
--   Data Quality Monitoring requires Enterprise Edition or higher.
--   DMFs associate with tables and views (ALTER TABLE / ALTER VIEW).
--   All DMFs on one object share that object's DATA_METRIC_SCHEDULE.
--   TRIGGER_ON_CHANGES is documented for DML on tables, not views.
--   Expectation form: EXPECTATION name ( <boolean on VALUE> ).
--   Allowed operators include = < > <= >= AND OR BETWEEN-is-not-listed;
--   this file uses 800 <= VALUE AND VALUE <= 1200, not BETWEEN.

-- Target names come from config/target.sql ($demo_db, $demo_schema).
-- Run that file first in the same session. Do not hardcode the database here.

USE ROLE BT_BUILDER_ROLE;
USE WAREHOUSE BT_WH;
USE DATABASE IDENTIFIER($demo_db);
USE SCHEMA IDENTIFIER($demo_schema);

-- One-row counter. Incremented inside the load transaction, so an empty
-- load still gets an id. Reset sets it back to 0, so the values are
-- monotonic within a run, not across runs.
CREATE TABLE IF NOT EXISTS bt_batch_id (
  id NUMBER NOT NULL
)
COMMENT = 'Monotonic batch id. Latest attempt is MAX(bt_load_ledger.batch_id), never MAX(bt_orders.batch_id).';

INSERT INTO bt_batch_id (id)
SELECT 0
WHERE NOT EXISTS (SELECT 1 FROM bt_batch_id);

CREATE TABLE IF NOT EXISTS bt_orders (
  order_id    NUMBER        NOT NULL,
  line_no     NUMBER        NOT NULL,
  sku         VARCHAR       NOT NULL,
  qty         NUMBER        NOT NULL,
  load_ts     TIMESTAMP_LTZ NOT NULL,
  batch_id    NUMBER        NOT NULL
)
COMMENT = 'Synthetic orders. Business key is (order_id, line_no). load_ts is not part of the key.';

CREATE TABLE IF NOT EXISTS bt_load_ledger (
  batch_id     NUMBER        NOT NULL,
  batch_name   VARCHAR       NOT NULL,
  attempted_at TIMESTAMP_NTZ NOT NULL,
  row_count    NUMBER        NOT NULL,
  note         VARCHAR
)
COMMENT = 'One row per load attempt, including empty loads.';

-- Latest attempt comes from the ledger, including an empty attempt that
-- deleted every order row. MAX(batch_id) on bt_orders would miss that.
CREATE OR REPLACE VIEW bt_orders_latest_batch AS
SELECT o.order_id, o.line_no, o.sku, o.qty, o.load_ts, o.batch_id
FROM bt_orders o
WHERE o.batch_id = (
  SELECT MAX(l.batch_id) FROM bt_load_ledger l
);

-- Separate object so its schedule is not tied to the duplicate check.
-- Freshness is measured on this view's load_ts, which is the latest batch only.
CREATE OR REPLACE VIEW bt_orders_latest_freshness AS
SELECT o.order_id, o.line_no, o.load_ts, o.batch_id
FROM bt_orders o
WHERE o.batch_id = (
  SELECT MAX(l.batch_id) FROM bt_load_ledger l
);
