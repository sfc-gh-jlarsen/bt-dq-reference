# Data quality reference

**Drop the DMF associations or they keep billing (~312 evaluations/day).** `99_teardown.sql` does that drop. A suspended warehouse does not.

Customer-neutral reference for three system data metric functions on synthetic order lines. The repo is the deliverable. An account deploy is a check that the SQL runs, not a second artifact.

Nothing here is a customer workload. Object names start with `bt_`. Data is generated in the account and never loaded from a file.

## What it checks

| Check | Object | DMF | Expectation | Schedule |
| --- | --- | --- | --- | --- |
| Duplicate business key | `bt_orders` | `DUPLICATE_COUNT(order_id, line_no)` | `VALUE = 0` | `TRIGGER_ON_CHANGES` |
| Latest attempt volume | `bt_orders_latest_batch` | `ROW_COUNT()` | `800 <= VALUE AND VALUE <= 1200` | `5 MINUTE` |
| Latest attempt freshness | `bt_orders_latest_freshness` | `FRESHNESS(load_ts)` | `VALUE < 900` | `USING CRON 0 * * * * UTC` |

The business key is `(order_id, line_no)`. Each generated order has lines 1 through 5, so `order_id` repeats inside a good batch and `DUPLICATE_COUNT(order_id)` is not the pair check. `load_ts` is not part of the key, so a replay of the same lines with a new timestamp is a duplicate of the pair.

`bt_load_ledger` records every attempt, including a load of zero rows, in the same transaction as the change to `bt_orders`. The latest-batch views read `MAX(batch_id)` from the ledger. They do not use `MAX(batch_id)` from `bt_orders`, which would skip an empty load that deleted the table.

Batch ids come from `bt_batch_id`, a one-row table incremented inside the load transaction. An empty load still advances it. The proof resets the counter to 0, so the ids are monotonic within a run, not across runs. `MAX(batch_id)` on the ledger remains the definition of "latest attempt."

## Walkthrough

`config/target.sql` is the only place the database and schema names are set. The SQL files read `$demo_db` and `$demo_schema`. Change the two assignments in that file to retarget the scripts. Do not type a manual `USE DATABASE` instead of running the file.

```
snow sql -f config/target.sql -f sql/00_setup.sql
```

`config/target.sql` currently contains:

```sql
SET demo_db = 'BT_DQ_REF';
SET demo_schema = 'BT_DQ_REF';
```

`snow sql` stops the file when a statement fails and does not execute the later statements, including `COMMIT`. A failed statement inside `BEGIN` does not roll the earlier statements back by itself. Each batch therefore starts with `ROLLBACK`, so a rerun after a stop clears the partial transaction instead of committing it. Leave those `ROLLBACK` lines in place.

1. `sql/00_setup.sql` creates the counter table, the two data tables, and the two views.
2. `sql/01_generate.sql` runs the four batches. Optional if you only want the proof.
3. `sql/02_monitors.sql` attaches the three DMFs and their schedules.
4. `sql/03_prove.sql` resets the tables and prints the proof. It calls `DUPLICATE_COUNT` on `order_id` only as a contrast. The pair rows use `SYSTEM$DATA_METRIC_SCAN` on `(order_id, line_no)`. Freshness is a direct call. The row-count rows are `COUNT(*)` on the view. It does not read `DATA_QUALITY_MONITORING_RESULTS`.
5. `sql/99_teardown.sql` is not part of the proof. It drops the DMF associations, the demo objects, and the schema named by `$demo_schema`. It does not drop the database. It suspends `BT_WH` last and never drops it, because that warehouse may be shared.

Batches, same shape in `01_generate.sql` and `03_prove.sql`:

| Name | Rows | What it does |
| --- | --- | --- |
| `good` | 1000 | Replaces the table with 200 orders of 5 lines, unique `(order_id, line_no)` |
| `duplicate_replay` | 1000 | Inserts those same keys again with a later `load_ts` |
| `empty` | 0 | Deletes `bt_orders` and still writes a ledger row |
| `spike` | 10000 | Replaces the table with 10000 rows, same 5-line shape |

The sizes are fixed in the SQL. There is no row-count argument.

## How to read the proof

`03_prove.sql` is the acceptance check. A row is one manual measurement.

A good batch meets the expectation, so `result` is `PASS`. A bad batch does not, so `result` is `FAIL`. The column is that comparison. It is not flipped to mean "the check worked."

The pair is the acceptance check. `order_id` alone is a contrast, because each order has five lines:

- `SYSTEM$DATA_METRIC_SCAN` with `DUPLICATE_COUNT` and `ARGUMENT_NAME => 'order_id, line_no'` returns the duplicate rows. The proof counts those rows. Docs checked 2026-11-02: a direct call cannot take more than one column, and the scan function is the documented way to ask the DMF for the failing rows of that combination. The good batch expects 0 rows. The replay expects a number other than 0, so `result` is `FAIL`.
- `SNOWFLAKE.CORE.DUPLICATE_COUNT(SELECT order_id FROM bt_orders)` is one column. On the good batch this is already not 0, because lines 1 through 5 share an `order_id`. That row is labeled "not the pair check." A direct call of `order_id || '-' || line_no` fails with `DUPLICATE_COUNT$V1: (VARCHAR(134217728))`.
- `SNOWFLAKE.CORE.FRESHNESS(SELECT load_ts FROM bt_orders_latest_freshness)` is a direct call. It accepts `DATE`, `TIMESTAMP_LTZ`, or `TIMESTAMP_TZ`. `TIMESTAMP_NTZ` is rejected, so `load_ts` is `TIMESTAMP_LTZ`.

`ROW_COUNT` cannot be called directly. `SYSTEM$DATA_METRIC_SCAN` does not accept it either; that function returns the failing rows for a short list of DMFs, not the metric value. The row-count proof is `COUNT(*)` on `bt_orders_latest_batch`, the same row set the scheduled DMF reads. That row is labeled as a count of the view, not as a DMF call.

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

- `99_teardown.sql` drops the DMF associations, the demo tables and views, and the schema in `$demo_schema`. `BT_BUILDER_ROLE` owns that schema, which is why `DROP SCHEMA` is in the file. The database stays. There is no `DROP DATABASE` and no `DROP WAREHOUSE`. `BT_WH` may be shared: the file suspends it at the end and does not drop it.
- The role needs `EXECUTE DATA METRIC FUNCTION` on the account to call a system DMF. That grant is not created by this repo. It was already present on the build role.
- `DUPLICATE_COUNT` on more than one column cannot be called directly. The docs (checked 2026-11-02) say to associate it, and `SYSTEM$DATA_METRIC_SCAN` returns the failing rows for that combination. The proof counts those rows. `DUPLICATE_COUNT(order_id)` is printed beside it and is not the pair result, because `line_no` is not always 1.
- `ROW_COUNT` is attached to the view and scheduled. The proof measures the view with `COUNT(*)` because the DMF itself cannot be called directly and the scan function does not accept it.
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
