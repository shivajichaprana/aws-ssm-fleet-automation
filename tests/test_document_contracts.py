"""Contracts between the runbooks and the documents they call.

A runbook names a Command document by string and passes it a parameter map. Nothing
checks that the document exists, that it accepts those parameter names, or that the
values the runbook allows are values the document allows - not until the step runs,
mid-execution, against real nodes. Renaming a document file or tightening one of its
allowedValues is exactly the kind of change that breaks this silently.
"""

from __future__ import annotations

from ssm_documents import (
    AUTOMATION_DOCUMENTS,
    COMMAND_DOCUMENTS,
    DOCUMENT_NAME_PATTERN,
    PUBLISHED_SUFFIX,
    REFERENCE_PATTERN,
    parameter_defaults,
    terraform_name_prefix,
    violates_constraint,
)

#: Documents owned by AWS rather than this repository. Their contract is fixed by
#: AWS, so the local resolution rules do not apply to them.
AWS_MANAGED_DOCUMENTS = {"AWS-RunPatchBaseline", "AWS-UpdateSSMAgent"}

#: The only patch operations a runbook may ask for.
PATCH_OPERATIONS = {"Scan", "Install"}

NAME_PREFIX = terraform_name_prefix()
COMMAND_DOCUMENTS_BY_STEM = {document.stem: document for document in COMMAND_DOCUMENTS}


def _sole_reference(value):
    """The parameter name when *value* is exactly one ``{{ ref }}``, else ``None``."""
    if not isinstance(value, str):
        return None
    matches = REFERENCE_PATTERN.findall(value)
    if len(matches) != 1:
        return None
    if REFERENCE_PATTERN.sub("", value).strip():
        return None
    return matches[0]


def _resolve_document_name(runbook, raw_name):
    """Resolve a step's ``DocumentName`` to a literal, following one indirection.

    A runbook either names a document outright or passes a parameter whose default
    names it. Anything else is resolved only at run time and is skipped.
    """
    if not isinstance(raw_name, str):
        return None
    reference = _sole_reference(raw_name)
    if reference is None:
        return raw_name
    parameter = runbook.parameters.get(reference)
    if parameter is None:
        return None
    defaults = parameter_defaults(parameter)
    return defaults[0] if defaults else None


def _local_document_for(literal_name):
    """The Command document a published name refers to, or ``None``."""
    prefix = NAME_PREFIX + "-"
    if not literal_name.startswith(prefix):
        return None
    return COMMAND_DOCUMENTS_BY_STEM.get(literal_name[len(prefix):])


def _run_command_steps():
    for runbook in AUTOMATION_DOCUMENTS:
        for step in runbook.main_steps:
            if step.get("action") == "aws:runCommand":
                yield runbook, step


def test_every_called_document_resolves():
    """Each runbook step calls a document this repo publishes, or an AWS-managed one."""
    checked = 0
    for runbook, step in _run_command_steps():
        raw_name = (step.get("inputs") or {}).get("DocumentName")
        literal = _resolve_document_name(runbook, raw_name)
        assert literal is not None, (
            "{}: step {!r} calls {!r}, which cannot be resolved to a document name; "
            "give the parameter a default".format(runbook.stem, step.get("name"), raw_name)
        )
        assert DOCUMENT_NAME_PATTERN.match(literal), (
            "{}: step {!r} resolves to invalid document name {!r}".format(
                runbook.stem, step.get("name"), literal
            )
        )
        if literal in AWS_MANAGED_DOCUMENTS:
            checked += 1
            continue
        assert _local_document_for(literal) is not None, (
            "{}: step {!r} calls {!r}, but no documents/<name>{} publishes under that "
            "name with prefix {!r}. Renaming a document file means updating the "
            "runbook defaults that call it.".format(
                runbook.stem, step.get("name"), literal, PUBLISHED_SUFFIX, NAME_PREFIX
            )
        )
        checked += 1
    assert checked, "no aws:runCommand steps were inspected"


def test_passed_parameters_are_accepted_by_the_called_document():
    """A runbook may only pass parameter names the target document declares."""
    for runbook, step in _run_command_steps():
        inputs = step.get("inputs") or {}
        passed = inputs.get("Parameters") or {}
        if not passed:
            continue
        literal = _resolve_document_name(runbook, inputs.get("DocumentName"))
        target = _local_document_for(literal or "")
        if target is None:
            continue
        for name in passed:
            assert name in target.parameters, (
                "{}: step {!r} passes {!r} to {}, which does not declare it".format(
                    runbook.stem, step.get("name"), name, target.stem
                )
            )


def test_passed_values_are_acceptable_to_the_called_document():
    """What the runbook permits must be a subset of what the document permits.

    Both literal values and forwarded parameters are covered: a forwarded parameter
    is checked by every value it is allowed to carry, so widening the runbook's
    allowedValues past the document's fails here rather than at run time.
    """
    for runbook, step in _run_command_steps():
        inputs = step.get("inputs") or {}
        passed = inputs.get("Parameters") or {}
        literal_name = _resolve_document_name(runbook, inputs.get("DocumentName"))
        target = _local_document_for(literal_name or "")
        if target is None:
            continue

        for name, values in passed.items():
            target_parameter = target.parameters.get(name)
            if target_parameter is None:
                continue  # covered by the acceptance test above
            for value in values:
                reference = _sole_reference(value)
                if reference is None:
                    reason = violates_constraint(target_parameter, str(value))
                    assert reason is None, (
                        "{}: step {!r} passes {} to {}: {}".format(
                            runbook.stem, step.get("name"), name, target.stem, reason
                        )
                    )
                    continue

                source = runbook.parameters.get(reference)
                assert source is not None, (
                    "{}: step {!r} forwards undeclared parameter {!r}".format(
                        runbook.stem, step.get("name"), reference
                    )
                )
                candidates = [
                    str(item) for item in (source.get("allowedValues") or [])
                ] or parameter_defaults(source)
                for candidate in candidates:
                    reason = violates_constraint(target_parameter, candidate)
                    assert reason is None, (
                        "{}: {} may carry {!r} into {}.{}, which rejects it - {}".format(
                            runbook.stem, reference, candidate, target.stem, name, reason
                        )
                    )


def test_patch_operations_are_scan_or_install():
    """The patch document takes free-form parameters; only two values make sense."""
    seen = set()
    for runbook, step in _run_command_steps():
        inputs = step.get("inputs") or {}
        if _resolve_document_name(runbook, inputs.get("DocumentName")) != "AWS-RunPatchBaseline":
            continue
        operations = (inputs.get("Parameters") or {}).get("Operation") or []
        assert operations, (
            "{}: step {!r} runs the patch document without an Operation".format(
                runbook.stem, step.get("name")
            )
        )
        for operation in operations:
            assert operation in PATCH_OPERATIONS, (
                "{}: step {!r} asks for patch operation {!r}".format(
                    runbook.stem, step.get("name"), operation
                )
            )
            seen.add(operation)
    if seen:
        assert "Scan" in seen, (
            "a patch runbook installs without ever scanning, so approval would be "
            "given against an unknown state"
        )


def test_read_only_runbooks_change_nothing():
    """A runbook advertised as read-only must not call a converging document."""
    read_only = {"collect-node-diagnostics"}
    converging = {"host-hardening", "service-convergence"}
    for runbook, step in _run_command_steps():
        if runbook.stem not in read_only:
            continue
        literal = _resolve_document_name(runbook, (step.get("inputs") or {}).get("DocumentName"))
        target = _local_document_for(literal or "")
        assert target is None or target.stem not in converging, (
            "{} is documented as read-only but step {!r} runs {}".format(
                runbook.stem, step.get("name"), target.stem
            )
        )
        assert literal != "AWS-RunPatchBaseline" or "Install" not in str(
            (step.get("inputs") or {}).get("Parameters", {})
        ), "{} is documented as read-only but installs patches".format(runbook.stem)
