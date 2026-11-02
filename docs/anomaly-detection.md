# Anomaly detection (docs only)

Not enabled in this demo. Do not turn it on without Joe's approval.

## What the current docs say

Schema-level monitoring can attach `SNOWFLAKE.CORE.ROW_COUNT` or `SNOWFLAKE.CORE.FRESHNESS` and set `ANOMALY_DETECTION = TRUE`. Snowflake then trains a model and flags unusual volume or freshness per object, not for the schema as a whole.

```sql
ALTER SCHEMA some_schema
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.ROW_COUNT ON ()
    ANOMALY_DETECTION = TRUE;
```

Source: https://docs.snowflake.com/en/user-guide/data-quality-schema-level

That statement is not in `sql/`. Running it would start serverless training and scheduled evaluations on every supported object in the schema. The demo schema is small, but the cost is real and the feature applies to each supported object in it.

## Why this repo does not turn it on

- The acceptance proof is a direct DMF call with a fixed threshold. Anomaly detection replaces the threshold with a trained model, which cannot be shown before/after in one script.
- Training needs a history of measurements. A fresh synthetic table has none, so the first runs would not demonstrate a useful signal.
- `TABLE_SIZE_BYTES` is documented as not supporting anomaly detection. The other two schema-level DMFs do.

## What a later phase would measure first

1. Run the good batch for several scheduled intervals and read `DATA_QUALITY_MONITORING_RESULTS` so there is a baseline.
2. Enable anomaly detection on one object, not the schema.
3. Compare the anomaly flag against the same failure modes already in `03_prove.sql` (empty, spike, duplicate, stale).
4. Record the serverless credits before disabling it.
