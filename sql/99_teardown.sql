-- 99_teardown.sql
-- Drops the objects this demo created, then drops the demo schema.
-- Does not drop the database. Does not drop the warehouse.
--
-- BT_BUILDER_ROLE owns the schema, so DROP SCHEMA succeeds.
-- The database was provisioned for the demo and stays when the demo is done.
-- Never DROP DATABASE.
--
-- BT_WH may be shared with other demos. Suspend it as housekeeping so an idle
-- shared warehouse is not left running. Never drop it.
-- Suspend is last so the drops above still have a running warehouse.
-- The suspend is not a cost control. Dropping the DMF associations is what
-- stops serverless billing. A suspended warehouse does not stop those schedules.
--
-- This file is not part of the proof. Do not run it until the proof is kept.

-- Target names come from config/target.sql ($demo_db, $demo_schema).
-- Run that file first in the same session. No database name is hardcoded here.

USE ROLE BT_BUILDER_ROLE;
USE WAREHOUSE BT_WH;
USE DATABASE IDENTIFIER($demo_db);
USE SCHEMA IDENTIFIER($demo_schema);

-- Listing is the record of what this demo owns. Printed before the drops.
SHOW TABLES;
SHOW VIEWS;

ALTER TABLE IF EXISTS IDENTIFIER($demo_db || '.' || $demo_schema || '.bt_orders')
  DROP DATA METRIC FUNCTION SNOWFLAKE.CORE.DUPLICATE_COUNT ON (order_id, line_no);
-- The custom DMF is only created by notebooks/04_custom_dmf.ipynb.
ALTER TABLE IF EXISTS IDENTIFIER($demo_db || '.' || $demo_schema || '.bt_orders')
  DROP DATA METRIC FUNCTION IDENTIFIER($demo_db || '.' || $demo_schema || '.bt_positive_qty')
  ON (qty);
ALTER VIEW IF EXISTS IDENTIFIER($demo_db || '.' || $demo_schema || '.bt_orders_latest_batch')
  DROP DATA METRIC FUNCTION SNOWFLAKE.CORE.ROW_COUNT ON ();
ALTER VIEW IF EXISTS IDENTIFIER($demo_db || '.' || $demo_schema || '.bt_orders_latest_freshness')
  DROP DATA METRIC FUNCTION SNOWFLAKE.CORE.FRESHNESS ON (load_ts);

DROP VIEW IF EXISTS IDENTIFIER($demo_db || '.' || $demo_schema || '.bt_orders_latest_freshness');
DROP VIEW IF EXISTS IDENTIFIER($demo_db || '.' || $demo_schema || '.bt_orders_latest_batch');
DROP TABLE IF EXISTS IDENTIFIER($demo_db || '.' || $demo_schema || '.bt_orders');
DROP TABLE IF EXISTS IDENTIFIER($demo_db || '.' || $demo_schema || '.bt_load_ledger');
DROP TABLE IF EXISTS IDENTIFIER($demo_db || '.' || $demo_schema || '.bt_batch_id');

DROP FUNCTION IF EXISTS IDENTIFIER($demo_db || '.' || $demo_schema || '.bt_positive_qty')(TABLE(NUMBER));

-- Examples stay commented, so these objects are not created by this repo.
-- Uncomment only if you created them by hand.
-- DROP TASK IF EXISTS bt_baseline_task;
-- DROP NOTIFICATION INTEGRATION IF EXISTS bt_dq_notify;

-- Schema only. The database stays.
DROP SCHEMA IF EXISTS IDENTIFIER($demo_db || '.' || $demo_schema);

-- Shared warehouse. Suspend as housekeeping, never drop. Last, after the drops above.
-- This suspend does not stop DMF billing. The association drops above do that.
ALTER WAREHOUSE BT_WH SUSPEND;
