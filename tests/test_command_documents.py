"""Schema and convention checks for the Run Command documents.

These documents are what State Manager runs against the fleet on a schedule, so a
defect in one is not a build failure - it is a fleet-wide misconfiguration that
recurs on an interval. Every check below stands for a way one of them could be
published successfully and still be wrong.
"""

from __future__ import annotations

import re

import pytest

from ssm_documents import (
    COMMAND_ACTIONS,
    COMMAND_DOCUMENT_DIR,
    COMMAND_DOCUMENTS,
    PUBLISHED_SUFFIX,
    STEP_NAME_PATTERN,
    body_without_parameters,
    collect_references,
    is_constrained,
    local_documents_referenced_by_terraform,
    parameter_defaults,
    violates_constraint,
)

#: Every document must handle both halves of a mixed fleet, because one association
#: targets nodes by tag without distinguishing their platform.
REQUIRED_PLATFORMS = {"Linux", "Windows"}

#: Interpreter guards. A shell step without ``set -euo pipefail`` reports success
#: for a pipeline whose first command failed, which State Manager then records as a
#: compliant node.
SHELL_GUARD = "set -euo pipefail"
POWERSHELL_GUARD = "$ErrorActionPreference = 'Stop'"


def test_documents_are_present():
    """The suite is worthless if it silently covers nothing."""
    assert COMMAND_DOCUMENTS, "no Command documents were discovered in documents/"


def test_only_published_suffixes_are_present():
    """Terraform globs ``*.yml``; another suffix is ignored rather than rejected."""
    stray = [
        path.name
        for path in COMMAND_DOCUMENT_DIR.iterdir()
        if path.is_file()
        and path.suffix in {".yaml", ".json"}
        and path.suffix != PUBLISHED_SUFFIX
    ]
    assert not stray, (
        "these files would never be published because the fileset only matches "
        "*{}: {}".format(PUBLISHED_SUFFIX, stray)
    )


def test_schema_version_is_the_command_schema(command_document):
    """2.2 must stay a string: YAML would otherwise read it as the float 2.2."""
    schema_version = command_document.body.get("schemaVersion")
    assert schema_version == "2.2", (
        "expected the string '2.2', got {!r} - quote it in YAML".format(schema_version)
    )


def test_document_describes_itself(command_document):
    description = command_document.body.get("description", "")
    assert isinstance(description, str) and description.strip(), (
        "a published document with no description is undiscoverable in the console"
    )


def test_steps_are_named_uniquely(command_document):
    names = command_document.step_names
    assert names, "a document with no mainSteps does nothing"
    assert len(names) == len(set(names)), "step names must be unique: {}".format(names)
    for name in names:
        assert STEP_NAME_PATTERN.match(name or ""), "invalid step name {!r}".format(name)


def test_steps_use_supported_actions(command_document):
    for step in command_document.main_steps:
        assert step.get("action") in COMMAND_ACTIONS, (
            "step {!r} uses unsupported action {!r}".format(
                step.get("name"), step.get("action")
            )
        )


def test_every_step_is_guarded_by_a_platform_precondition(command_document):
    """A shell step reaching a Windows node fails noisily and pointlessly."""
    for step in command_document.main_steps:
        precondition = step.get("precondition") or {}
        equals = precondition.get("StringEquals")
        assert equals and equals[0] == "platformType", (
            "step {!r} has no platformType precondition, so it would run on every "
            "platform".format(step.get("name"))
        )
        assert equals[1] in REQUIRED_PLATFORMS, (
            "step {!r} targets unknown platform {!r}".format(step.get("name"), equals[1])
        )


def test_document_covers_both_platforms(command_document):
    platforms = {
        (step.get("precondition") or {}).get("StringEquals", [None, None])[1]
        for step in command_document.main_steps
    }
    assert REQUIRED_PLATFORMS <= platforms, (
        "a tag-selected association cannot tell platforms apart, so every document "
        "must handle {} - this one covers {}".format(sorted(REQUIRED_PLATFORMS), sorted(platforms))
    )


def test_steps_declare_a_numeric_timeout(command_document):
    """Systems Manager wants the timeout as a string, but it must still be a number."""
    for step in command_document.main_steps:
        timeout = (step.get("inputs") or {}).get("timeoutSeconds")
        assert isinstance(timeout, str), (
            "step {!r} must quote timeoutSeconds".format(step.get("name"))
        )
        assert timeout.isdigit() and int(timeout) > 0, (
            "step {!r} has a non-numeric timeout {!r}".format(step.get("name"), timeout)
        )


def test_steps_carry_a_command_body(command_document):
    for step in command_document.main_steps:
        run_command = (step.get("inputs") or {}).get("runCommand")
        assert isinstance(run_command, list) and run_command, (
            "step {!r} has no runCommand body".format(step.get("name"))
        )


def test_interpreter_guards_are_present(command_document):
    """Failure has to propagate, or a broken run is recorded as a compliant node."""
    for step in command_document.main_steps:
        body = "\n".join((step.get("inputs") or {}).get("runCommand", []))
        if step.get("action") == "aws:runShellScript":
            assert SHELL_GUARD in body, (
                "shell step {!r} is missing {!r}".format(step.get("name"), SHELL_GUARD)
            )
        else:
            assert POWERSHELL_GUARD in body, (
                "PowerShell step {!r} is missing {!r}".format(
                    step.get("name"), POWERSHELL_GUARD
                )
            )


def test_parameters_are_described_and_constrained(command_document):
    """An unconstrained String parameter is an injection point into a root shell."""
    for name, parameter in command_document.parameters.items():
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


def test_parameter_defaults_satisfy_their_own_constraint(command_document):
    """A default the document itself would reject fails only at registration."""
    for name, parameter in command_document.parameters.items():
        for value in parameter_defaults(parameter):
            reason = violates_constraint(parameter, value)
            assert reason is None, "default for {!r}: {}".format(name, reason)


def test_allowed_patterns_compile(command_document):
    for name, parameter in command_document.parameters.items():
        pattern = parameter.get("allowedPattern")
        if pattern is None:
            continue
        try:
            re.compile(pattern)
        except re.error as error:  # pragma: no cover - only on a broken pattern
            pytest.fail("allowedPattern for {!r} does not compile: {}".format(name, error))


def test_every_reference_resolves_to_a_parameter(command_document):
    """A Command document has no step outputs, so every reference is a parameter."""
    declared = set(command_document.parameters)
    for reference in collect_references(body_without_parameters(command_document)):
        assert reference in declared, (
            "step body references {{{{ {} }}}} which is not a declared parameter".format(
                reference
            )
        )


def test_every_parameter_is_consumed(command_document):
    """A parameter nothing reads is a knob the operator turns to no effect."""
    used = collect_references(body_without_parameters(command_document))
    unused = sorted(set(command_document.parameters) - used)
    assert not unused, "declared but never referenced: {}".format(unused)


def test_associations_reference_documents_that_exist():
    """Every ``local_document`` in the shipped defaults names a real file."""
    available = {document.stem for document in COMMAND_DOCUMENTS}
    for referenced in local_documents_referenced_by_terraform():
        assert referenced in available, (
            "an association names local_document {!r}, but documents/{}{} does not "
            "exist".format(referenced, referenced, PUBLISHED_SUFFIX)
        )
