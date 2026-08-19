# Document validation

Systems Manager validates a document's schema when it is registered, and nothing
else. It does not check that a runbook's branch points at a real step, that a
`DocumentName` resolves to a document that exists, that a forwarded parameter is a
value the target document accepts, or that the shell inside a Command document
parses at all. Those defects register cleanly and surface later — during a real
execution, on real nodes, usually while somebody is waiting.

This suite asks those questions locally instead. It reads the documents from the
working tree with the same glob Terraform uses, so what it inspects is exactly what
gets published, and it needs no credentials and makes no API calls.

## Running

```bash
pip install -r tests/requirements.txt
python -m pytest tests -q
```

Everything is offline. `bash -n` is used to parse rendered shell bodies and is
skipped automatically on a machine without `bash`.

## Layout

| File | What it covers |
| --- | --- |
| `ssm_documents.py` | Loading, reference extraction, and constraint evaluation shared by the suites |
| `conftest.py` | Discovers documents from disk and parametrises every suite over them |
| `test_command_documents.py` | Command document schema, platform preconditions, parameter constraints, interpreter guards |
| `test_automation_runbooks.py` | Runbook schema, control-flow graph, step outputs, rate limiting, approval gates |
| `test_document_contracts.py` | Contracts between a runbook and the document it calls |
| `test_step_scripts.py` | Rendered script bodies: shell parses, nothing unresolved, substitutions quoted |

## Conventions the suite enforces

Adding a document to `documents/` or a runbook to `automation/` puts it under every
check below automatically — there is no registration step to forget.

- **`schemaVersion` stays a string.** Unquoted, YAML reads `2.2` as a float and the
  document is rejected on registration.
- **Every Command document handles both platforms.** One association selects nodes
  by tag and cannot tell a Linux node from a Windows one, so each document carries a
  `platformType` precondition on both halves.
- **Every parameter is constrained.** An unconstrained `String` reaches an
  interpreter running as root. `allowedValues` or an `allowedPattern` is required,
  and each default must satisfy its own constraint.
- **Every parameter is consumed, and every reference resolves.** A parameter nothing
  reads is a knob that does nothing; a reference to a parameter that does not exist
  reaches the node as a literal `{{ ... }}`.
- **Failure propagates.** Shell steps set `set -euo pipefail` and PowerShell steps
  set `$ErrorActionPreference`, so a failed step is recorded as non-compliant rather
  than passing silently.
- **Substitutions are quoted.** A bare `{{ value }}` word-splits as soon as a value
  contains a space.
- **Runbook control flow is closed.** Branch targets, explicit successors, and
  document-level outputs all resolve to steps and outputs that exist.
- **Fleet-wide commands are rate limited.** A tag-selected `aws:runCommand` declares
  `MaxConcurrency`, `MaxErrors`, and `TimeoutSeconds`, so a bad change stops inside
  an error budget instead of sweeping the slice.
- **Called documents exist and agree.** A runbook may only call a document this repo
  publishes (or an AWS-managed one), may only pass parameter names that document
  declares, and may only permit values that document permits.

## Known limitations

- **PowerShell is checked structurally, not parsed.** No PowerShell parser is
  available on a Linux runner, so those bodies are checked for balanced delimiters
  and unresolved references rather than full syntax.
- **Terraform wiring is checked by regex, not by evaluation.** The suite reads the
  `name_prefix` default and the `local_document` values out of `variables.tf` to
  resolve published names. Terraform's own `validate` and the plan-time preconditions
  cover the rest.
- **Nothing is executed.** Scripts are parsed, never run, so behaviour on a real node
  is out of scope by design.
