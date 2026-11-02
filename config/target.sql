-- Default target for this demo. Change these two lines to point the
-- scripts at another database and schema. The SQL files read $demo_db and
-- $demo_schema; they do not contain the names themselves.
--
-- snow sql -f config/target.sql -f sql/00_setup.sql
--
-- Set both before any script. An unset variable is an error, not a fallback.

SET demo_db = 'BT_DQ_REF';
SET demo_schema = 'BT_DQ_REF';
