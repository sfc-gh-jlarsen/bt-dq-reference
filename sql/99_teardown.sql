-- 99_teardown.sql
-- Drops the objects this demo created. Does not drop the schema.
-- Does not drop the database. Does not drop the warehouse.
--
-- The database and the schema are provisioned for the demo and stay when
-- the demo is done. Ownership of both is outside this repo. Do not grant
-- yourself that ownership to widen the drop.

-- Target names come from config/target.sql ($demo_db, $demo_schema).
-- Run that file first in the same session. Do not hardcode the database here.

USE ROLE BT_BUILDER_ROLE;
USE WAREHOUSE BT_WH;
USE DATABASE IDENTIFIER($demo_db);
USE SCHEMA IDENTIFIER($demo_schema);

ALTER WAREHOUSE BT_WH SUSPEND;

-- Listing is the record of what this demo owns. Printed before the drops.
-- These SHOW statements use the session database and schema from above.
SHOW TABLES;
SHOW VIEWS;

USE SCHEMA IDENTIFIER($demo_schema);

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
--
-- The schema and the database stay. They were provisioned for the demo.
