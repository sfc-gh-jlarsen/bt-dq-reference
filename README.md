# Data quality reference

Customer-neutral reference for three system data metric functions on synthetic order lines. The repo is the deliverable. An account deploy is a check that the SQL runs, not a second artifact.

Nothing here is a customer workload. Object names start with `bt_`. Data is generated in the account and never loaded from a file.

## What it checks

| Check | Object | DMF | Expectation | Schedule |
| --- | --- | --- | --- | --- |
| Duplicate business key | `bt_orders` | `DUPLICATE_COUNT(order_id, line_no)` | `VALUE = 0` | `TRIGGER_ON_CHANGES` |
| Latest attempt volume | `bt_orders_latest_batch` | `ROW_COUNT()` | `800 <= VALUE AND VALUE <= 1200` | `5 MINUTE` |
| Latest attempt freshness | `bt_orders_latest_freshness` | `FRESHNESS(load_ts)` | `VALUE < 900` | `USING CRON 0 * * * * UTC` |

The business key is `(order_id, line_no)`. `load_ts` is not part of that key, so a replay of the same lines with a new timestamp is a duplicate.

`bt_load_ledger` records every attempt, including a load of zero rows, in the same transaction as the change to `bt_orders`. The latest-batch views read `MAX(batch_id)` from the ledger. They do not use `MAX(batch_id)` from `bt_orders`, which would skip an empty load that deleted the table.

## Walkthrough

The database and schema are not written in the SQL files. `config/target.sql` sets `$demo_db` and `$demo_schema`. The default in that file is `BT_DQ_REF` and `BT_DQ_REF`. Change those two assignments to retarget the scripts. Run `config/target.sql` in the same session before any file under `sql/`.

```sql
-- config/target.sql
SET demo_db = 'BT_DQ_REF';
SET demo_schema = 'BT_DQ_REF';
```

`BT_BUILDER_ROLE` can create tables and views in that schema. It cannot create a sequence. Batch ids come from `bt_batch_id`, a one-row table incremented inside the load transaction. An empty load still advances it. `MAX(batch_id)` on the ledger remains the definition of "latest attempt."

Run in order, after the config file. `01_generate.sql` loads every batch once, as a demonstration. `03_prove.sql` resets and loads again, so you can skip `01` if you only want the proof.

```
snow sql -f config/target.sql -f sql/00_setup.sql
```

1. `sql/00_setup.sql` creates the counter table, the two data tables, and the two views.
2. `sql/01_generate.sql` runs the four batches inside transactions. It does not create a procedure.
3. `sql/02_monitors.sql` attaches the three DMFs and their schedules.
4. `sql/03_prove.sql` resets the tables and prints the proof. It calls `DUPLICATE_COUNT` and `FRESHNESS` directly. The row-count rows are `COUNT(*)` on the view. It does not read `DATA_QUALITY_MONITORING_RESULTS`.
5. `sql/99_teardown.sql` suspends the warehouse, lists objects, and drops the demo tables and views. It does not drop the schema. It does not drop the database.

Batches, same shape in `01_generate.sql` and `03_prove.sql`:

| Name | Rows | What it does |
| --- | --- | --- |
| `good` | 1000 | Replaces the table with keys `(1..1000, 1)` |
| `duplicate_replay` | 1000 | Inserts those same keys again with a later `load_ts` |
| `empty` | 0 | Deletes `bt_orders` and still writes a ledger row |
| `spike` | 10000 | Replaces the table with 10000 rows |

The sizes are fixed in the SQL. There is no row-count argument.

## How to read the proof

`03_prove.sql` is the acceptance check. A row is one manual measurement.

A good batch meets the expectation, so `result` is `PASS`. A bad batch does not, so `result` is `FAIL`. The column is that comparison. It is not flipped to mean "the check worked."

Two measurements are direct DMF calls:

- `SNOWFLAKE.CORE.DUPLICATE_COUNT(SELECT order_id FROM bt_orders)`. A direct call takes one column. Passing `order_id || '-' || line_no` fails with `DUPLICATE_COUNT$V1: (VARCHAR(134217728))`. The replay copies `order_id`, so the one-column call still sees 1000 duplicate values. The association in `02_monitors.sql` is the two-column form, which the docs say cannot be called directly.
- `SNOWFLAKE.CORE.FRESHNESS(SELECT load_ts FROM bt_orders_latest_freshness)`. A direct call accepts `DATE`, `TIMESTAMP_LTZ`, or `TIMESTAMP_TZ`. `TIMESTAMP_NTZ` is rejected, so `load_ts` is `TIMESTAMP_LTZ`.

`ROW_COUNT` cannot be called directly. `SYSTEM$DATA_METRIC_SCAN` does not accept it either; that function returns the failing rows for a short list of DMFs, not the metric value. The row-count proof is `COUNT(*)` on `bt_orders_latest_batch`, the same row set the scheduled DMF reads. That row is labeled as a count of the view, not as a DMF call. A third duplicate row is the same kind of label: a grouped count of `(order_id, line_no)`, not a DMF call.

Scheduled evaluation is a different path. `02_monitors.sql` writes future rows to the account data-quality event table. This repo does not query that table, wait for a schedule, or treat a scheduled row as the proof.

Freshness does not sleep. The stale batch inserts `load_ts` 3600 seconds in the past and the DMF is called immediately. The build run observed 3602.

## Docs this SQL follows

Checked against Snowflake docs on 2026-11-02:

- Data Quality Monitoring is an Enterprise Edition feature. Confirm the account edition before promising the scheduled path. Direct DMF calls are ordinary SQL and were executed on the build account.
- `ALTER TABLE` and `ALTER VIEW` both associate a DMF. `ROW_COUNT` takes `ON ()`.
- `DUPLICATE_COUNT` accepts more than one column. The value is the number of rows whose combined values are duplicated.
- Every DMF on one object shares that object's `DATA_METRIC_SCHEDULE`. Freshness has its own view so the hourly cron does not also move the row-count check off its 5-minute schedule.
- `TRIGGER_ON_CHANGES` is documented for DML on tables. It is not set on either view.
- Expectation syntax is `EXPECTATION name ( <expression> )`. `VALUE` is the DMF result. `BETWEEN` is not in the documented operator list, so the range is `800 <= VALUE AND VALUE <= 1200`.

## Limitations

- The database and the schema are provisioned outside this repo and stay after teardown. `99_teardown.sql` drops only the tables and views this demo created. It does not contain `DROP SCHEMA` or `DROP DATABASE`.
- `BT_BUILDER_ROLE` has `USAGE`, `CREATE TABLE`, and `CREATE VIEW` on the schema. It cannot create a sequence or a procedure, which is why batch ids are a one-row table and the generator is plain SQL.
- The role needs `EXECUTE DATA METRIC FUNCTION` on the account to call a system DMF. That grant is not created by this repo. It was already present on the build role.
- `DUPLICATE_COUNT` on `(order_id, line_no)` is attached, not called. A direct call is one column. The two-column number in the proof is a SQL aggregate and is labeled as one.
- `ROW_COUNT` is attached to the view and scheduled. The proof measures the view with `COUNT(*)` because the DMF itself cannot be called directly.
- Edition was not readable by `BT_BUILDER_ROLE` (`SNOWFLAKE.ORGANIZATION_USAGE` and `SNOWFLAKE.ACCOUNT_USAGE` are not granted). The scheduled path is documented as Enterprise Edition or higher. The build attached the three DMFs and set all three schedules without an edition error, which is consistent with that requirement but is not an edition query.
- Joining the latest-batch view to a second fact table can multiply rows. This repo does not demonstrate that. Join amplification is phase 2.
- No Streamlit app. Phase 2.
- Anomaly detection is described in `docs/anomaly-detection.md` and is not enabled.
- `examples/task_baseline.sql` and `examples/notifications.sql` are commented out. Running the commented blocks would create a task or a notification. Do not do that without an explicit approval.

## Cost

Serverless data-quality monitoring bills when a scheduled DMF runs, not when you call one yourself. This demo attaches three schedules, so leaving them in place spends credits even if nobody runs `03_prove.sql` again.

No invoice line for this demo was available at authoring time. Treat the figures below as estimates, not a measurement.

| Path | When it costs | Estimate |
| --- | --- | --- |
| `03_prove.sql` direct calls | Warehouse time on `BT_WH` while the script runs | One X-Small minute or less for the full script. Measure with `QUERY_HISTORY` on the build account if a number is required. |
| `DUPLICATE_COUNT` trigger | Each DML on `bt_orders` after `02_monitors.sql` | Serverless per change. A proof run does several writes, so a scheduled evaluation can land after the script finishes. |
| `ROW_COUNT` | Every 5 minutes for as long as the view keeps the schedule | The standing cost. 288 evaluations per day. |
| `FRESHNESS` | Hourly cron | 24 evaluations per day. |
| Idle warehouse | `99_teardown.sql` suspends `BT_WH` | A suspended warehouse does not bill compute. The DMF schedules are not the warehouse. They keep billing until the associations are dropped. |

Do not read "the warehouse is suspended" as "the demo costs nothing." Drop the DMF associations (`99_teardown.sql`) to stop the serverless schedules.

Credits per DMF evaluation depend on the account's serverless rate and the bytes scanned. Snowflake's data quality documentation describes the billing model; it does not publish a flat per-check credit figure, so this README does not invent one.
