"""Syntax checks on the script bodies the documents carry.

A Command document is registered as an opaque string: Systems Manager validates the
document schema, never the shell inside it. A stray ``fi`` is therefore discovered
on a production node at 03:00, by an association nobody was watching. Rendering the
scripts with their declared defaults and parsing them here closes that gap.
"""

from __future__ import annotations

import re
import shutil
import subprocess

import pytest

from ssm_documents import REFERENCE_PATTERN, parameter_defaults

#: Substituted for a parameter that is required at run time, so the rendered script
#: is syntactically complete without inventing a plausible-looking value.
PLACEHOLDER = "PLACEHOLDER"

BASH = shutil.which("bash")


def _render(document, step):
    """The step body with every ``{{ ref }}`` replaced by its declared default."""
    body = "\n".join((step.get("inputs") or {}).get("runCommand", []))

    def substitute(match):
        name = match.group(1)
        parameter = document.parameters.get(name, {})
        defaults = parameter_defaults(parameter)
        if not defaults:
            return PLACEHOLDER
        # A StringList arrives at the node comma joined, exactly as the scripts parse it.
        return ",".join(defaults) if len(defaults) > 1 else defaults[0]

    return REFERENCE_PATTERN.sub(substitute, body)


@pytest.mark.skipif(BASH is None, reason="bash is not available on this runner")
def test_shell_steps_parse(command_document):
    """``bash -n`` on the rendered body: parse only, nothing is executed."""
    for step in command_document.main_steps:
        if step.get("action") != "aws:runShellScript":
            continue
        rendered = _render(command_document, step)
        result = subprocess.run(
            [BASH, "-n"],
            input=rendered,
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert result.returncode == 0, (
            "{}: shell step {!r} does not parse:\n{}".format(
                command_document.stem, step.get("name"), result.stderr.strip()
            )
        )


def test_rendered_steps_have_no_unresolved_references(command_document):
    """Every placeholder must be substitutable, or the node receives a literal ``{{``."""
    for step in command_document.main_steps:
        rendered = _render(command_document, step)
        leftover = REFERENCE_PATTERN.findall(rendered)
        assert not leftover, (
            "{}: step {!r} still contains {} after substitution".format(
                command_document.stem, step.get("name"), leftover
            )
        )


def test_powershell_steps_are_balanced(command_document):
    """No PowerShell parser is available, so check the structure that breaks first."""
    for step in command_document.main_steps:
        if step.get("action") != "aws:runPowerShellScript":
            continue
        rendered = _render(command_document, step)
        for opener, closer in (("{", "}"), ("(", ")"), ("[", "]")):
            assert rendered.count(opener) == rendered.count(closer), (
                "{}: PowerShell step {!r} has unbalanced {}{}".format(
                    command_document.stem, step.get("name"), opener, closer
                )
            )


def test_shell_steps_quote_their_substitutions(command_document):
    """A bare substitution word-splits the moment a value contains a space."""
    bare = re.compile(r"(?<![\"'$])\{\{\s*[A-Za-z0-9_.]+\s*\}\}")
    for step in command_document.main_steps:
        if step.get("action") != "aws:runShellScript":
            continue
        body = "\n".join((step.get("inputs") or {}).get("runCommand", []))
        for line in body.splitlines():
            stripped = line.strip()
            if stripped.startswith("#"):
                continue
            assert not bare.search(stripped), (
                "{}: step {!r} interpolates without quoting: {!r}".format(
                    command_document.stem, step.get("name"), stripped
                )
            )
