"""Shared fixtures and parametrisation for the document validation suites.

Documents are discovered from disk with the same glob Terraform uses, so a new
document is covered by every test in this suite the moment the file is added -
there is no per-document registration to forget.
"""

from __future__ import annotations

from typing import List

import pytest

from ssm_documents import (
    AUTOMATION_DOCUMENTS,
    COMMAND_DOCUMENTS,
    SsmDocument,
    terraform_name_prefix,
)


def _ids(documents: List[SsmDocument]) -> List[str]:
    return [document.stem for document in documents]


def pytest_generate_tests(metafunc: pytest.Metafunc) -> None:
    """Parametrise any test that asks for a document fixture."""
    if "command_document" in metafunc.fixturenames:
        metafunc.parametrize(
            "command_document",
            COMMAND_DOCUMENTS,
            ids=_ids(COMMAND_DOCUMENTS),
        )
    if "automation_document" in metafunc.fixturenames:
        metafunc.parametrize(
            "automation_document",
            AUTOMATION_DOCUMENTS,
            ids=_ids(AUTOMATION_DOCUMENTS),
        )


@pytest.fixture(scope="session")
def name_prefix() -> str:
    """The resource name prefix a default deployment publishes documents under."""
    return terraform_name_prefix()


@pytest.fixture(scope="session")
def command_documents() -> List[SsmDocument]:
    return COMMAND_DOCUMENTS
