"""Schema and control-flow checks for the Automation runbooks.

An Automation runbook is a graph, and Systems Manager will happily register one
whose branch points at a step that does not exist. That failure surfaces halfway
through a real execution - after the approval has been given and the first half of
the change has already landed. These tests walk the graph before it ships.
"""

from __future__ import annotations

import re

import pytest

from ssm_documents import (
    ACTIONS_WITHOUT_ON_FAILURE,
    AUTOMATION_ACTIONS,
    AUTOMATION_DOCUMENT_DIR,
    AUTOMATION_DOCUMENTS,
    ON_FAILURE_VALUES,
    PUBLISHED_SUFFIX,
    STEP_NAME_PATTERN,
    body_without_parameters,
    collect_references,
    is_constrained,
    parameter_defaults,
    violates_constraint,
)

#: The parameter every runbook takes its identity from.
ASSUME_ROLE_PARAMETER = "AutomationAssumeRole"

#: Fleet-wide commands are rate limited, always. A runbook that omits either knob
#: sweeps the whole slice at once.
RATE_LIMIT_INPUTS = ("MaxConcurrency", "MaxErrors")


def _step_outputs(document):
    """Map of ``stepName -> {outputName}`` declared across the runbook."""
    return {
        step.get("name"): {
            output.get("Name") for output in (step.get("outputs") or [])
        }
        for step in document.main_steps
    }


def test_runbooks_are_present():
    assert AUTOMATION_DOCUMENTS, "no Automation runbooks were discovered in automation/"


def test_only_published_suffixes_are_present():
    stray = [
        path.name
        for path in AUTOMATION_DOCUMENT_DIR.iterdir()
        if path.is_file()
        and path.suffix in {".yaml", ".json"}
        and path.suffix != PUBLISHED_SUFFIX
    ]
    assert not stray, (
        "these files would never be published because the fileset only matches "
        "*{}: {}".format(PUBLISHED_SUFFIX, stray)
    )


def test_schema_version_is_the_automation_schema(automation_document):
    schema_version = automation_document.body.get("schemaVersion")
    assert schema_version == "0.3", (
        "expected the string '0.3', got {!r} - quote it in YAML".format(schema_version)
    )


def test_runbook_describes_itself(automation_document):
    description = automation_document.body.get("description", "")
    assert isinstance(description, str) and description.strip(), (
        "a runbook an operator reaches for during an incident must say what it does"
    )


def test_runbook_assumes_a_caller_supplied_role(automation_document):
    """Identity is an input, so the runbook never carries a hard-coded role."""
    assume_role = automation_document.body.get("assumeRole")
    assert assume_role == "{{{{ {} }}}}".format(ASSUME_ROLE_PARAMETER), (
        "assumeRole must be {{{{ {} }}}}, got {!r}".format(ASSUME_ROLE_PARAMETER, assume_role)
    )
    assert ASSUME_ROLE_PARAMETER in automation_document.parameters, (
        "{} is referenced but not declared".format(ASSUME_ROLE_PARAMETER)
    )


def test_steps_are_named_uniquely(automation_document):
    names = automation_document.step_names
    assert names, "a runbook with no mainSteps does nothing"
    assert len(names) == len(set(names)), "step names must be unique: {}".format(names)
    for name in names:
        assert STEP_NAME_PATTERN.match(name or ""), "invalid step name {!r}".format(name)


def test_steps_use_supported_actions(automation_document):
    for step in automation_document.main_steps:
        assert step.get("action") in AUTOMATION_ACTIONS, (
            "step {!r} uses unsupported action {!r}; the automation role is scoped to "
            "the actions in use".format(step.get("name"), step.get("action"))
        )


def test_steps_declare_an_explicit_failure_disposition(automation_document):
    """Whether a failure aborts or is tolerated is a decision, not a default."""
    for step in automation_document.main_steps:
        if step.get("action") in ACTIONS_WITHOUT_ON_FAILURE:
            continue
        on_failure = step.get("onFailure")
        assert on_failure in ON_FAILURE_VALUES, (
            "step {!r} must set onFailure to one of {}, got {!r}".format(
                step.get("name"), sorted(ON_FAILURE_VALUES), on_failure
            )
        )


def test_runbook_has_a_terminal_step(automation_document):
    terminal = [step for step in automation_document.main_steps if step.get("isEnd")]
    assert terminal, "no step is marked isEnd, so the runbook falls off the end"


def test_control_flow_targets_exist(automation_document):
    """Every branch target and explicit successor names a declared step."""
    names = set(automation_document.step_names)
    for step in automation_document.main_steps:
        next_step = step.get("nextStep")
        if next_step is not None:
            assert next_step in names, (
                "step {!r} continues to unknown step {!r}".format(
                    step.get("name"), next_step
                )
            )
        if step.get("action") != "aws:branch":
            continue
        inputs = step.get("inputs") or {}
        for choice in inputs.get("Choices") or []:
            assert choice.get("NextStep") in names, (
                "branch {!r} points at unknown step {!r}".format(
                    step.get("name"), choice.get("NextStep")
                )
            )
        default = inputs.get("Default")
        assert default in names, (
            "branch {!r} has default {!r}, which is not a step".format(
                step.get("name"), default
            )
        )


def test_step_outputs_are_well_formed(automation_document):
    for step in automation_document.main_steps:
        for output in step.get("outputs") or []:
            assert output.get("Name"), (
                "an output of step {!r} has no Name".format(step.get("name"))
            )
            selector = output.get("Selector", "")
            assert selector.startswith("$."), (
                "output {!r} of step {!r} has selector {!r}; it must be a JSONPath "
                "expression".format(output.get("Name"), step.get("name"), selector)
            )
            assert output.get("Type"), (
                "output {!r} of step {!r} declares no Type".format(
                    output.get("Name"), step.get("name")
                )
            )


def test_parameters_are_described_and_constrained(automation_document):
    for name, parameter in automation_document.parameters.items():
        assert parameter.get("type") in {"String", "StringList"}, (
            "parameter {!r} has unsupported type {!r}".format(name, parameter.get("type"))
        )
        assert (parameter.get("description") or "").strip(), (
            "parameter {!r} has no description".format(name)
        )
        assert is_constrained(parameter), (
            "parameter {!r} accepts any value; give it allowedValues or an "
            "allowedPattern".format(name)
        )


def test_parameter_defaults_satisfy_their_own_constraint(automation_document):
    for name, parameter in automation_document.parameters.items():
        for value in parameter_defaults(parameter):
            reason = violates_constraint(parameter, value)
            assert reason is None, "default for {!r}: {}".format(name, reason)


def test_allowed_patterns_compile(automation_document):
    for name, parameter in automation_document.parameters.items():
        pattern = parameter.get("allowedPattern")
        if pattern is None:
            continue
        try:
            re.compile(pattern)
        except re.error as error:  # pragma: no cover - only on a broken pattern
            pytest.fail("allowedPattern for {!r} does not compile: {}".format(name, error))


def test_every_reference_resolves(automation_document):
    """A reference is either a parameter or an output some step actually produces."""
    declared = set(automation_document.parameters)
    outputs = _step_outputs(automation_document)

    for reference in collect_references(body_without_parameters(automation_document)):
        if reference in declared:
            continue
        assert "." in reference, (
            "{{{{ {} }}}} is neither a parameter nor a step output".format(reference)
        )
        step_name, _, output_name = reference.partition(".")
        assert step_name in outputs, (
            "{{{{ {} }}}} refers to unknown step {!r}".format(reference, step_name)
        )
        assert output_name in outputs[step_name], (
            "step {!r} does not declare an output named {!r}".format(step_name, output_name)
        )


def test_every_parameter_is_consumed(automation_document):
    used = collect_references(body_without_parameters(automation_document))
    unused = sorted(set(automation_document.parameters) - used)
    assert not unused, "declared but never referenced: {}".format(unused)


def test_document_outputs_are_produced_by_a_step(automation_document):
    """A documented output that no step produces is empty in every execution."""
    outputs = _step_outputs(automation_document)
    for entry in automation_document.body.get("outputs") or []:
        step_name, _, output_name = entry.partition(".")
        assert step_name in outputs, (
            "document output {!r} names unknown step {!r}".format(entry, step_name)
        )
        assert output_name in outputs[step_name], (
            "document output {!r} is not produced by step {!r}".format(entry, step_name)
        )


def test_fleet_wide_commands_are_rate_limited(automation_document):
    """A tag-selected command without a ceiling reaches the whole slice at once."""
    for step in automation_document.main_steps:
        if step.get("action") != "aws:runCommand":
            continue
        inputs = step.get("inputs") or {}
        if "Targets" not in inputs:
            continue
        for knob in RATE_LIMIT_INPUTS:
            assert inputs.get(knob), (
                "step {!r} targets by tag without {}".format(step.get("name"), knob)
            )
        assert inputs.get("TimeoutSeconds"), (
            "step {!r} sets no TimeoutSeconds".format(step.get("name"))
        )


def test_approval_steps_bound_their_wait(automation_document):
    """An approval that never expires holds an execution open indefinitely."""
    for step in automation_document.main_steps:
        if step.get("action") != "aws:approve":
            continue
        timeout = step.get("timeoutSeconds")
        assert isinstance(timeout, int) and timeout > 0, (
            "approval step {!r} needs a positive timeoutSeconds, got {!r}".format(
                step.get("name"), timeout
            )
        )
        inputs = step.get("inputs") or {}
        assert inputs.get("MinRequiredApprovals"), (
            "approval step {!r} does not say how many approvals it needs".format(
                step.get("name")
            )
        )
        assert inputs.get("Approvers") is not None, (
            "approval step {!r} names no approvers".format(step.get("name"))
        )
