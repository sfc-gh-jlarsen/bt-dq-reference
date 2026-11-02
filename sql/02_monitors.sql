-- 02_monitors.sql
-- System DMFs only. Schedules are attached but this demo does not wait
-- for them and does not read DATA_QUALITY_MONITORING_RESULTS for the proof.
-- Direct calls live in 03_prove.sql.
--
-- Schedule rule from current docs: every DMF on one object shares that
-- object's DATA_METRIC_SCHEDULE. That is why freshness is a separate view.
-- TRIGGER_ON_CHANGES is a table DML trigger. It is not used on views.

-- Target names come from config/target.sql ($demo_db, $demo_schema).
-- Run that file first in the same session. Do not hardcode the database here.

USE ROLE BT_BUILDER_ROLE;
USE WAREHOUSE BT_WH;
USE DATABASE IDENTIFIER($demo_db);
USE SCHEMA IDENTIFIER($demo_schema);

-- Duplicates follow writes to the base table.
ALTER TABLE bt_orders SET DATA_METRIC_SCHEDULE = 'TRIGGER_ON_CHANGES';

ALTER TABLE bt_orders
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.DUPLICATE_COUNT
    ON (order_id, line_no)
    EXPECTATION no_duplicate_keys (VALUE = 0);

-- Volume of the latest *attempt*, including an empty attempt (the view
-- returns 0 rows when the ledger's newest batch deleted the table).
-- 5 minute cadence. Not a cron, so it is not tied to the freshness view.
ALTER VIEW bt_orders_latest_batch SET DATA_METRIC_SCHEDULE = '5 MINUTE';

ALTER VIEW bt_orders_latest_batch
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.ROW_COUNT
    ON ()
    EXPECTATION rows_800_to_1200 (800 <= VALUE AND VALUE <= 1200);

-- Freshness on its own object so the cron does not also reschedule ROW_COUNT.
-- Expectation is age under 900 seconds. Proof uses bt_age_latest_load,
-- not a sleep.
ALTER VIEW bt_orders_latest_freshness SET
  DATA_METRIC_SCHEDULE = 'USING CRON 0 * * * * UTC';

ALTER VIEW bt_orders_latest_freshness
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.FRESHNESS
    ON (load_ts)
    EXPECTATION fresher_than_900s (VALUE < 900);
