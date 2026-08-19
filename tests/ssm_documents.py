"""Loading and inspection helpers shared by the document validation suites.

Systems Manager rejects a malformed document at registration time, which means a
mistake in a document is only discovered when Terraform tries to publish it - after
the plan has been reviewed and applied. The helpers here let the suite answer the
same questions locally, before anything is pushed.

Nothing in this module talks to AWS. Documents are read from the working tree
exactly as Terraform reads them, so what the tests inspect is what gets published.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Iterator, List, Optional, Set

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent

#: Command documents, published one per file as ``<name_prefix>-<file stem>``.
COMMAND_DOCUMENT_DIR = REPO_ROOT / "documents"

#: Automation runbooks, published the same way from their own directory.
AUTOMATION_DOCUMENT_DIR = REPO_ROOT / "automation"

#: Terraform discovers documents with ``fileset(..., "*.yml")``. A file saved with
#: any other suffix is silently ignored rather than rejected, so the suffix is
#: pinned here and asserted on.
PUBLISHED_SUFFIX = ".yml"

#: ``{{ Something }}`` or ``{{ stepName.OutputName }}``. Systems Manager tolerates
#: surrounding whitespace, so the pattern does too.
REFERENCE_PATTERN = re.compile(r"{{\s*([A-Za-z0-9_][A-Za-z0-9_.]*)\s*}}")

#: The only actions a Command document may use here. Both appear in every document
#: so that a single association can cover a mixed fleet.
COMMAND_ACTIONS = {"aws:runShellScript", "aws:runPowerShellScript"}

#: Automation actions in use. Extending this set is a deliberate act: each action
#: carries its own blast radius, and the least-privilege automation role is scoped
#: to match what the runbooks actually do.
AUTOMATION_ACTIONS = {
    "aws:runCommand",
    "aws:executeAwsApi",
    "aws:assertAwsResourceProperty",
    "aws:approve",
    "aws:branch",
}

#: ``aws:branch`` selects its own successor, so it is the one action that does not
#: carry an explicit failure disposition.
ACTIONS_WITHOUT_ON_FAILURE = {"aws:branch"}

#: Failure dispositions Systems Manager accepts on an Automation step.
ON_FAILURE_VALUES = {"Abort", "Continue"}

STEP_NAME_PATTERN = re.compile(r"^[A-Za-z0-9_-]{3,128}$")
DOCUMENT_NAME_PATTERN = re.compile(r"^[A-Za-z0-9_.-]{3,128}$")


@dataclass(frozen=True)
class SsmDocument:
    """A parsed Systems Manager document together with its source path."""

    path: Path
    body: Dict[str, Any]

    @property
    def stem(self) -> str:
        """File stem, which is also the suffix of the published document name."""
        return self.path.stem

    @property
    def parameters(self) -> Dict[str, Any]:
        return self.body.get("parameters") or {}

    @property
    def main_steps(self) -> List[Dict[str, Any]]:
        return self.body.get("mainSteps") or []

    @property
    def step_names(self) -> List[str]:
        return [step.get("name") for step in self.main_steps]

    def published_name(self, name_prefix: str) -> str:
        return "{}-{}".format(name_prefix, self.stem)

    def __str__(self) -> str:  # pragma: no cover - used for pytest ids only
        return str(self.path.relative_to(REPO_ROOT))


def load_documents(directory: Path) -> List[SsmDocument]:
    """Parse every published document in *directory*, sorted for stable test ids."""
    documents: List[SsmDocument] = []
    for path in sorted(directory.glob("*" + PUBLISHED_SUFFIX)):
        with path.open(encoding="utf-8") as handle:
            body = yaml.safe_load(handle)
        if not isinstance(body, dict):
            raise AssertionError("{} does not parse as a YAML mapping".format(path))
        documents.append(SsmDocument(path=path, body=body))
    return documents


def walk_strings(node: Any) -> Iterator[str]:
    """Yield every string anywhere inside a parsed document."""
    if isinstance(node, str):
        yield node
    elif isinstance(node, dict):
        for value in node.values():
            for text in walk_strings(value):
                yield text
    elif isinstance(node, list):
        for value in node:
            for text in walk_strings(value):
                yield text


def collect_references(node: Any) -> Set[str]:
    """Every ``{{ ... }}`` reference reachable from *node*."""
    found: Set[str] = set()
    for text in walk_strings(node):
        found.update(REFERENCE_PATTERN.findall(text))
    return found


def body_without_parameters(document: SsmDocument) -> Dict[str, Any]:
    """The document minus its parameter declarations.

    Parameter descriptions are prose and must not be mistaken for usage when
    checking that every declared parameter is actually consumed somewhere.
    """
    return {key: value for key, value in document.body.items() if key != "parameters"}


def parameter_defaults(parameter: Dict[str, Any]) -> List[str]:
    """Default value(s) of a parameter, normalised to a list of strings.

    A ``StringList`` default is a YAML list and a ``String`` default is a scalar;
    both are flattened so a caller validates every value the same way. A parameter
    with no default is required at run time and yields nothing.
    """
    if "default" not in parameter:
        return []
    default = parameter["default"]
    if isinstance(default, list):
        return [str(item) for item in default]
    return [str(default)]


def is_constrained(parameter: Dict[str, Any]) -> bool:
    """True when a parameter restricts what a caller is allowed to pass."""
    return bool(parameter.get("allowedValues") or parameter.get("allowedPattern"))


def violates_constraint(parameter: Dict[str, Any], value: str) -> Optional[str]:
    """Return why *value* is unacceptable to *parameter*, or ``None`` if it is fine.

    Mirrors the two constraints Systems Manager enforces itself, so a value that
    would be rejected on registration is rejected here first.
    """
    allowed_values = parameter.get("allowedValues")
    if allowed_values is not None:
        permitted = [str(item) for item in allowed_values]
        if value not in permitted:
            return "{!r} is not one of {}".format(value, permitted)

    allowed_pattern = parameter.get("allowedPattern")
    if allowed_pattern is not None and not re.match(allowed_pattern, value):
        return "{!r} does not match {!r}".format(value, allowed_pattern)

    return None


def terraform_name_prefix() -> str:
    """The ``name_prefix`` default declared in ``variables.tf``.

    Documents are published as ``<name_prefix>-<file stem>`` and the runbooks carry
    defaults naming the documents they call, so reading the real default keeps that
    contract checkable rather than restating it in two places.
    """
    variables = (REPO_ROOT / "variables.tf").read_text(encoding="utf-8")
    match = re.search(
        r'variable\s+"name_prefix"\s*\{.*?default\s*=\s*"([^"]+)"',
        variables,
        re.DOTALL,
    )
    if match is None:
        raise AssertionError("variables.tf no longer declares a default for name_prefix")
    return match.group(1)


def local_documents_referenced_by_terraform() -> List[str]:
    """Every ``local_document`` value named by the shipped association defaults."""
    variables = (REPO_ROOT / "variables.tf").read_text(encoding="utf-8")
    return re.findall(r'local_document\s*=\s*"([^"]+)"', variables)


COMMAND_DOCUMENTS = load_documents(COMMAND_DOCUMENT_DIR)
AUTOMATION_DOCUMENTS = load_documents(AUTOMATION_DOCUMENT_DIR)
