# Automation runbooks

Every `*.yml` file in this directory is published as a Systems Manager Automation document
by `automation.tf`. The Terraform picks the directory up with `fileset`, so adding a
runbook is a matter of dropping a file here — the published name is
`<name_prefix>-<filename without extension>`.

Associations and maintenance windows cover what the fleet does on a schedule. These cover
the rest: the patch that cannot wait for the next window, the node that stopped
converging, the hardening baseline that ships switched off and is adopted deliberately.

## Runbooks

| File | Published as | What it does | Changes state | Approval |
|---|---|---|---|---|
| `patch-on-demand.yml` | `<prefix>-patch-on-demand` | Scans a tag-selected slice, pauses for approval, installs approved patches, re-reports patch state | Yes | Default on, can be waived |
| `collect-node-diagnostics.yml` | `<prefix>-collect-node-diagnostics` | Confirms a node is reachable, runs the diagnostics document on it, returns the output inline | No | Not applicable |
| `apply-hardening-baseline.yml` | `<prefix>-apply-hardening-baseline` | Snapshots a slice, gets approval, applies the hardening document, verifies the nodes still answer | Yes | Mandatory |

## Conventions

- **Tag-selected, never instance-selected.** Runbooks that act on a slice target it by tag,
  exactly as the maintenance windows do. The one runbook that takes an instance ID is the
  read-only diagnostic, where a single node is the point.
- **Look before you change.** A runbook that changes state captures the current state
  first, so the approver decides against evidence rather than an assumption.
- **Approval is a step, not a convention.** Anything that rewrites host configuration
  passes through `aws:approve`. The execution expires rather than proceeding if nobody
  approves, so an unattended request never becomes an unattended change.
- **Verify afterwards.** The step after a change confirms the fleet still answers. A node
  that configured itself out of reach surfaces in the run that did it.
- **Failure modes are chosen, not defaulted.** `onFailure` is set explicitly on every step:
  `Abort` where continuing would compound a problem, `Continue` where the step is reporting
  and its failure is not the operator's problem.
- **Parameters are constrained.** Every parameter declares `allowedValues` or an
  `allowedPattern`, so a runbook cannot be handed a value its steps do not expect.

## Document names in defaults

Runbooks that call a published Command document take its name as a parameter, defaulted to
the name produced by the default `name_prefix`. A fleet deployed under a different prefix
passes its own names, which `terraform output ssm_document_names` lists.

## Running one

```bash
aws ssm start-automation-execution \
  --document-name "fleet-patch-on-demand" \
  --parameters '{
    "TargetTagValue": ["linux-non-production"],
    "RequireApproval": ["false"],
    "AutomationAssumeRole": ["arn:aws:iam::123456789012:role/fleet-automation"]
  }'
```

Track it with `aws ssm describe-automation-executions` and read the result with
`aws ssm get-automation-execution --automation-execution-id <id>`.
