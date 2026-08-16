# aws-ssm-fleet-automation

Fleet operations for EC2 and hybrid managed nodes built on AWS Systems Manager, shipped
as Terraform. Patching, configuration convergence, inventory, and interactive access are
described as data and applied consistently across every node in the fleet.

## Capabilities

| Capability | What it does |
|---|---|
| Patch management | Patch baselines with explicit approval rules, patch groups, and rate-limited maintenance windows that run the patch operation on a schedule |
| Configuration convergence | State Manager associations that keep agents, packages, and settings at their declared state |
| Inventory and compliance | Systems Manager Inventory with a resource data sync so fleet state is queryable outside the console |
| Interactive access | Session Manager with hardened, audited logging in place of inbound SSH and bastion hosts |

Patch management, configuration convergence, and inventory ship today; interactive access
lands in the same configuration and reuses the same tagging model.

## How nodes are selected

Everything is tag driven. A managed node joins a patch baseline by carrying the
`Patch Group` tag, and joins a maintenance window because that window targets the same
tag value. No instance IDs appear anywhere in this configuration, so a node scales in or
out of the fleet purely by how it is tagged.

```hcl
# Tag applied to the instance (or its launch template) elsewhere in your estate.
tags = {
  "Patch Group" = "linux-production"
}
```

## Repository layout

| Path | Purpose |
|---|---|
| `versions.tf` | Terraform and provider version constraints |
| `providers.tf` | Regional provider with default tags |
| `variables.tf` | Fleet configuration surface: baselines, windows, retention, roles |
| `patch-baselines.tf` | Patch baselines, patch groups, maintenance windows and their tasks |
| `state-manager.tf` | Published Command documents and the State Manager associations that run them |
| `documents/` | Run Command documents published to Systems Manager, one per file |
| `inventory.tf` | Inventory collection, the hardened sync destination, and the resource data sync |
| `compliance.tf` | Read-only compliance reporter, its notification topic, and its schedule |
| `lambda/compliance-reporter/` | Function that turns compliance state into a digest |
| `outputs.tf` | Identifiers other configurations and runbooks consume |

## Configuration convergence

A maintenance window patches the fleet on a cadence. An association does something
different: it keeps re-asserting a declared state, and reports a node that has drifted away
from it as non-compliant. Both are described the same way — a document, a tag-selected
slice of the fleet, a schedule, and a rate limit.

Every `*.yml` file in [`documents/`](documents/) is published as a Command document
automatically, so a new one is added to the fleet by adding a file. Associations reference
either a published document (`local_document`) or an AWS-managed one (`document_name`).

| Association | Document | Cadence | Effect |
|---|---|---|---|
| `agent-update` | `AWS-UpdateSSMAgent` | Every 14 days | Keeps the agent current so every other capability keeps working |
| `patch-scan` | `AWS-RunPatchBaseline` | Daily | Reports patch compliance between install windows without changing the node |
| `service-convergence` | `service-convergence` | Hourly | Holds the agent services at enabled and running |
| `fleet-diagnostics` | `fleet-diagnostics` | Twice daily | Surfaces a host low on disk or memory as non-compliant |
| `host-hardening` | `host-hardening` | Weekly, **off by default** | Converges hosts onto the ssh and SMB hardening baseline |

An association carrying `enabled = false` stays described in configuration but is not
created. That is how a document which rewrites host configuration ships ready to adopt
rather than switched on — review the values, flip the flag, and apply.

```hcl
state_manager_associations = {
  host-hardening = {
    local_document              = "host-hardening"
    schedule_expression         = "cron(0 5 ? * SUN *)"
    apply_only_at_cron_interval = true
    max_concurrency             = "5%"
    max_errors                  = "1"
    enabled                     = true

    targets = [
      {
        key    = "tag:Patch Group"
        values = ["linux-non-production"]
      },
    ]
  }
}
```

Systems Manager truncates the output it returns inline. Set `association_output_s3_bucket`
to an existing bucket to keep the full log of every run.

## Inventory and compliance

Patching and convergence act on the fleet. Inventory answers the prior question — what is
actually running out there — and compliance answers the operational one: which nodes are
currently out of line, on what, and how badly.

### Collection

One inventory association covers the fleet. Systems Manager permits exactly one per
managed node, so it is declared separately from the convergence associations rather than
as another entry alongside them. Categories are configured as booleans:

```hcl
inventory_collection = {
  applications                  = true
  instance_detailed_information = true
  network_config                = true
  services                      = true
  billing_info                  = false

  # File and registry collection are JSON documents, not flags. Left unset, neither is
  # collected — they are the categories that grow inventory volume fastest.
  files = jsonencode([{ Path = "/etc", Pattern = ["*.conf"], Recursive = false }])
}
```

### Where the data goes

Systems Manager keeps inventory for a limited window, which is long enough to answer a
question and too short to see a trend. The resource data sync copies inventory and
compliance data into S3 continuously, so fleet history survives and can be read with
ordinary data tools rather than through the API.

The destination bucket is created and hardened here unless `inventory_sync_bucket_name`
points at an existing one: object ownership enforced, public access blocked, versioning
on, encrypted with a rotating customer managed key, TLS required, and lifecycle expiry at
`inventory_retention_days`. The bucket policy grants Systems Manager exactly the write it
needs — scoped to the sync prefix and to this account's partition of it, nothing wider.

### The compliance digest

| | |
|---|---|
| What it reports | Fleet-wide compliant and non-compliant counts per compliance type, then the specific nodes failing at the severities you asked for |
| How it is delivered | A JSON report object under a date partition, plus a truncated digest published to a topic |
| How often | `compliance_report_schedule_expression`, weekly by default |
| What it changes | Nothing |

The reporter is read only by construction. It lists compliance state, writes its own
report object, and publishes a message — it never remediates a node, retriggers an
association, or changes a baseline. Remediation stays a deliberate act: a maintenance
window that installs patches, or an association switched on after review.

```hcl
compliance_report_severities        = ["CRITICAL", "HIGH"]
compliance_notification_emails      = ["platform-oncall@example.invalid"]
compliance_max_resources_in_summary = 25
```

Findings are ordered worst-first — severity, then how many items are failing — and the
published message is capped so a bad week does not produce an unreadable email. The full
set always stays in the report object.

## Getting started

```bash
terraform init
terraform plan
terraform apply
```

The shipped defaults create Amazon Linux 2 and Windows baselines, four patch groups, and
three weekly maintenance windows. Override `patch_baselines` and `maintenance_windows` to
describe your own fleet.

```hcl
module "fleet" {
  source = "github.com/<your-github-org>/aws-ssm-fleet-automation?ref=v1.0.0"

  aws_region  = "us-east-1"
  name_prefix = "platform"

  maintenance_windows = {
    linux-production = {
      patch_group     = "linux-production"
      schedule        = "cron(0 3 ? * SAT *)"
      duration        = 4
      cutoff          = 1
      operation       = "Install"
      max_concurrency = "10%"
      max_errors      = "2%"
    }
  }
}
```

## Prerequisites

- The SSM Agent installed and running on every managed node.
- An instance profile granting the node `AmazonSSMManagedInstanceCore`.
- Network reachability to the Systems Manager endpoints, either through a NAT path or
  through interface VPC endpoints for `ssm`, `ssmmessages`, and `ec2messages`.

## Design principles

- **Tag driven, never instance driven.** Fleet membership is a tag, so the configuration
  never needs to change when the fleet does.
- **Approval rules over blanket auto-approval.** Patches age for a defined period and are
  filtered by classification and severity before they are approved.
- **Rate limited by default.** Every window carries a concurrency ceiling and an error
  budget so a bad patch stops rather than sweeps the fleet.
- **Auditable output.** Patch command output is captured to CloudWatch Logs with an
  explicit retention period and optional customer managed encryption.
- **Idempotent convergence.** A document run against a node already in the declared state
  makes no change and succeeds, so a short association interval is safe. A node that did
  not converge exits non-zero and shows up as non-compliant.
- **Reporting never remediates.** The compliance reporter only reads state and publishes
  it. Anything that changes a node is an explicit, reviewable action elsewhere in this
  configuration.
- **Templates, not device operations.** This repository ships infrastructure as code with
  placeholder values; it is never executed against a live account from here.

## License

MIT — see [LICENSE](LICENSE).
