-- 99_teardown.sql
-- Drops demo objects in the current schema, then the schema.
-- Never drops the database. Never drops a warehouse.
--
-- Schema ownership on the assigned database is ACCOUNTADMIN, not
-- BT_BUILDER_ROLE. If DROP SCHEMA fails, the object drops above it have
-- still removed the demo tables, views, procedures, and sequence.
-- Do not grant yourself ownership to force the schema drop.

USE ROLE BT_BUILDER_ROLE;
USE WAREHOUSE BT_WH;
USE DATABASE BT_DQ_REF;
USE SCHEMA BT_DQ_REF;

ALTER WAREHOUSE BT_WH SUSPEND;

-- Listing is the record of what this demo owns. Printed before the drops.
SHOW TABLES IN SCHEMA BT_DQ_REF.BT_DQ_REF;
SHOW VIEWS IN SCHEMA BT_DQ_REF.BT_DQ_REF;
SHOW PROCEDURES IN SCHEMA BT_DQ_REF.BT_DQ_REF;

USE SCHEMA BT_DQ_REF;

ALTER TABLE IF EXISTS bt_orders
  DROP DATA METRIC FUNCTION SNOWFLAKE.CORE.DUPLICATE_COUNT ON (order_id, line_no);
ALTER VIEW IF EXISTS bt_orders_latest_batch
  DROP DATA METRIC FUNCTION SNOWFLAKE.CORE.ROW_COUNT ON ();
ALTER VIEW IF EXISTS bt_orders_latest_freshness
  DROP DATA METRIC FUNCTION SNOWFLAKE.CORE.FRESHNESS ON (load_ts);

DROP VIEW IF EXISTS bt_orders_latest_freshness;
DROP VIEW IF EXISTS bt_orders_latest_batch;
DROP TABLE IF EXISTS bt_orders;
DROP TABLE IF EXISTS bt_load_ledger;
DROP TABLE IF EXISTS bt_batch_id;

-- Examples stay commented, so these objects are not created by this repo.
-- Uncomment only if you created them by hand.
-- DROP TASK IF EXISTS bt_baseline_task;
-- DROP NOTIFICATION INTEGRATION IF EXISTS bt_dq_notify;

DROP SCHEMA IF EXISTS BT_DQ_REF.BT_DQ_REF;
