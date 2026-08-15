# Run Command documents

Every `*.yml` file in this directory is published as a Systems Manager Command document by
`state-manager.tf`. The Terraform picks the directory up with `fileset`, so adding a
document is a matter of dropping a file here — the published name is
`<name_prefix>-<filename without extension>`.

## Documents

| File | Published as | What it does | Changes state |
|---|---|---|---|
| `fleet-diagnostics.yml` | `<prefix>-fleet-diagnostics` | Reports agent version, uptime, filesystem and memory utilisation, and pending-reboot status | No |
| `service-convergence.yml` | `<prefix>-service-convergence` | Enables and starts a declared set of services, then verifies they are running | Yes |
| `host-hardening.yml` | `<prefix>-host-hardening` | Turns off remote root login and password authentication on Linux, disables SMB1 on Windows | Yes |

## Conventions

Documents in this directory follow a small set of rules so they behave predictably when
State Manager runs them on a schedule against a whole fleet.

- **Schema 2.2, one step per platform.** Each document carries a `aws:runShellScript` step
  and a `aws:runPowerShellScript` step, each guarded by a `platformType` precondition, so a
  single association covers a mixed fleet.
- **Idempotent.** Running a document against a node that is already in the declared state
  makes no changes and succeeds. That is what makes a short schedule interval safe.
- **Exit status carries meaning.** A document exits non-zero when the node is not in the
  declared state, so State Manager compliance reflects reality instead of reporting success
  for a node that never converged.
- **Validate before adopting.** A step that rewrites configuration builds the new file in a
  temporary location, validates it, and only then replaces the live file — keeping a backup.
- **Fail closed on shell errors.** Shell steps run under `set -euo pipefail`; PowerShell
  steps set `$ErrorActionPreference = 'Stop'` and strict mode.
- **Parameters are constrained.** Every parameter declares `allowedValues` or an
  `allowedPattern` so an association cannot pass something the script does not expect.

## Running one on demand

```bash
aws ssm send-command \
  --document-name "fleet-fleet-diagnostics" \
  --targets 'Key=tag:Patch Group,Values=linux-production' \
  --parameters 'utilisationWarnPercent=90' \
  --max-concurrency 10% \
  --max-errors 5%
```
