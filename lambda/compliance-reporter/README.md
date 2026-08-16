# Compliance reporter

Turns Systems Manager compliance state into a digest an operator can act on: fleet-wide
counts per compliance type, then the specific nodes that are non-compliant at the
severities worth paging about.

Systems Manager records compliance continuously — association convergence, patch state,
and any custom compliance a team registers — but it does not deliver a summary anywhere.
The console view is also a point-in-time window, whereas this report is written to S3 and
kept, so fleet compliance can be looked at as a trend rather than as a snapshot.

## Behaviour

The function is **strictly read only**. It lists compliance state, writes its own report
object, and publishes a message. It never remediates a node, retriggers an association, or
changes a patch baseline: remediation is a deliberate act, not a side effect of reporting.

1. Reads fleet-wide compliance counts for every compliance type.
2. Reads the non-compliant resource summaries and keeps those whose overall severity is in
   the configured list.
3. Sorts findings worst-first — severity, then how many items are failing.
4. Writes the full report as JSON to a date-partitioned S3 key.
5. Publishes a truncated, human-readable digest to the notification topic; the full detail
   stays in the report object.

## Configuration

| Environment variable | Default | Purpose |
|---|---|---|
| `REPORT_BUCKET` | *(empty)* | Bucket that receives report objects. Empty disables S3 delivery. |
| `REPORT_PREFIX` | `compliance-reports` | Key prefix for report objects. |
| `REPORT_KMS_KEY_ARN` | *(empty)* | Key used to encrypt the report object. Falls back to `AES256`. |
| `SNS_TOPIC_ARN` | *(empty)* | Topic that receives the digest. Empty disables notification. |
| `REPORT_SEVERITIES` | `CRITICAL,HIGH` | Overall severities a non-compliant resource must carry to be listed. |
| `MAX_RESOURCES_IN_SUMMARY` | `25` | Resources listed in the published message; the rest stay in the report object. |
| `LOG_LEVEL` | `INFO` | Python log level. |

## Permissions

Only list and describe calls against Systems Manager compliance, plus `s3:PutObject` on
the report prefix, `sns:Publish` on the notification topic, and use of the report key.
