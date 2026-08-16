"""Fleet compliance summariser.

Systems Manager records compliance for every managed node — whether its associations
converged, whether its approved patches are installed, and whatever custom compliance a
team has registered. The console shows that state, but it does not deliver it, and the
raw per-item detail is far too noisy to read on a cadence.

This function turns that state into a digest: fleet-wide counts per compliance type, then
the specific resources that are non-compliant at the severities an operator actually
wants paged about. The digest is written to S3 for history and published to a topic for
delivery.

It is strictly read only. It lists compliance state, writes its own report object, and
publishes a message. It never remediates a node, retriggers an association, or changes a
patch baseline — remediation is a deliberate act, not a side effect of reporting.
"""

from __future__ import annotations

import datetime as dt
import json
import logging
import os
from typing import Any, Dict, Iterator, List, Optional, Sequence

import boto3

LOGGER = logging.getLogger()
LOGGER.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

# Ordering used to rank findings. Anything Systems Manager reports outside this list is
# ranked last rather than dropped, so a new severity never silently disappears.
SEVERITY_ORDER: Sequence[str] = (
    "CRITICAL",
    "HIGH",
    "MEDIUM",
    "LOW",
    "INFORMATIONAL",
    "UNSPECIFIED",
)

DEFAULT_REPORT_SEVERITIES: Sequence[str] = ("CRITICAL", "HIGH")

# Systems Manager caps both compliance list calls at 50 items per page.
PAGE_SIZE = 50

_CLIENTS: Dict[str, Any] = {}


def _client(service: str) -> Any:
    """Return a cached boto3 client.

    Clients are created lazily so that importing this module costs nothing and so that
    tests can replace the cache wholesale.
    """
    if service not in _CLIENTS:
        _CLIENTS[service] = boto3.client(service)
    return _CLIENTS[service]


def _parse_csv_env(name: str, default: Sequence[str]) -> List[str]:
    """Read a comma-separated environment variable into an upper-cased list."""
    raw = os.environ.get(name, "")
    values = [item.strip().upper() for item in raw.split(",") if item.strip()]
    return values or [item.upper() for item in default]


def _int_env(name: str, default: int) -> int:
    """Read an integer environment variable, falling back on anything unparseable."""
    try:
        return int(os.environ[name])
    except (KeyError, TypeError, ValueError):
        return default


def _severity_rank(severity: Optional[str]) -> int:
    """Rank a severity for sorting; unknown severities sort last."""
    normalised = (severity or "UNSPECIFIED").upper()
    try:
        return SEVERITY_ORDER.index(normalised)
    except ValueError:
        return len(SEVERITY_ORDER)


def _paginate(service: str, operation: str, result_key: str, **kwargs: Any) -> Iterator[Dict[str, Any]]:
    """Walk a Systems Manager NextToken pagination loop, yielding each item."""
    client = _client(service)
    next_token: Optional[str] = None

    while True:
        request = dict(kwargs)
        request["MaxResults"] = PAGE_SIZE
        if next_token:
            request["NextToken"] = next_token

        response = getattr(client, operation)(**request)
        for item in response.get(result_key, []):
            yield item

        next_token = response.get("NextToken")
        if not next_token:
            return


def _severity_counts(summary: Optional[Dict[str, Any]]) -> Dict[str, int]:
    """Flatten a Systems Manager SeveritySummary into a plain severity -> count map."""
    severity_summary = (summary or {}).get("SeveritySummary", {}) or {}
    counts: Dict[str, int] = {}

    for severity in SEVERITY_ORDER:
        # The API spells these as CriticalCount, HighCount, InformationalCount, and so on.
        value = severity_summary.get(f"{severity.capitalize()}Count")
        if isinstance(value, int) and value > 0:
            counts[severity] = value

    return counts


def _fleet_summary() -> List[Dict[str, Any]]:
    """Fleet-wide compliant / non-compliant counts, one entry per compliance type."""
    summaries: List[Dict[str, Any]] = []

    for item in _paginate("ssm", "list_compliance_summaries", "ComplianceSummaryItems"):
        compliant = item.get("CompliantSummary", {}) or {}
        non_compliant = item.get("NonCompliantSummary", {}) or {}

        compliant_count = int(compliant.get("CompliantCount", 0) or 0)
        non_compliant_count = int(non_compliant.get("NonCompliantCount", 0) or 0)
        total = compliant_count + non_compliant_count

        summaries.append(
            {
                "compliance_type": item.get("ComplianceType", "Unknown"),
                "compliant_count": compliant_count,
                "non_compliant_count": non_compliant_count,
                "total_count": total,
                # Reported as a whole percent; a compliance type with nothing recorded is
                # 100% rather than a division by zero.
                "compliant_percent": round((compliant_count / total) * 100, 1) if total else 100.0,
                "non_compliant_by_severity": _severity_counts(non_compliant),
            }
        )

    summaries.sort(key=lambda entry: (-entry["non_compliant_count"], entry["compliance_type"]))
    return summaries


def _resource_findings(report_severities: Sequence[str]) -> List[Dict[str, Any]]:
    """Non-compliant resources at or above the severities the operator asked for."""
    wanted = {severity.upper() for severity in report_severities}
    findings: List[Dict[str, Any]] = []

    for item in _paginate(
        "ssm",
        "list_resource_compliance_summaries",
        "ResourceComplianceSummaryItems",
        Filters=[{"Key": "Status", "Values": ["NON_COMPLIANT"], "Type": "EQUAL"}],
    ):
        severity = (item.get("OverallSeverity") or "UNSPECIFIED").upper()
        if severity not in wanted:
            continue

        non_compliant = item.get("NonCompliantSummary", {}) or {}
        execution = item.get("ExecutionSummary", {}) or {}
        executed_at = execution.get("ExecutionTime")

        findings.append(
            {
                "resource_id": item.get("ResourceId", "unknown"),
                "resource_type": item.get("ResourceType", "ManagedInstance"),
                "compliance_type": item.get("ComplianceType", "Unknown"),
                "status": item.get("Status", "NON_COMPLIANT"),
                "overall_severity": severity,
                "non_compliant_count": int(non_compliant.get("NonCompliantCount", 0) or 0),
                "non_compliant_by_severity": _severity_counts(non_compliant),
                "last_execution": executed_at.isoformat() if isinstance(executed_at, dt.datetime) else None,
            }
        )

    # Worst first: severity, then how much is wrong, then a stable identifier.
    findings.sort(
        key=lambda entry: (
            _severity_rank(entry["overall_severity"]),
            -entry["non_compliant_count"],
            entry["resource_id"],
        )
    )
    return findings


def _build_report(report_severities: Sequence[str]) -> Dict[str, Any]:
    """Assemble the full report document."""
    generated_at = dt.datetime.now(dt.timezone.utc)

    fleet = _fleet_summary()
    findings = _resource_findings(report_severities)

    by_type: Dict[str, int] = {}
    for finding in findings:
        by_type[finding["compliance_type"]] = by_type.get(finding["compliance_type"], 0) + 1

    total_compliant = sum(entry["compliant_count"] for entry in fleet)
    total_non_compliant = sum(entry["non_compliant_count"] for entry in fleet)
    total = total_compliant + total_non_compliant

    return {
        "generated_at": generated_at.isoformat(),
        "reported_severities": [severity.upper() for severity in report_severities],
        "totals": {
            "compliant_count": total_compliant,
            "non_compliant_count": total_non_compliant,
            "compliant_percent": round((total_compliant / total) * 100, 1) if total else 100.0,
        },
        "compliance_types": fleet,
        "reported_resource_count": len(findings),
        "reported_resources_by_compliance_type": dict(sorted(by_type.items())),
        "non_compliant_resources": findings,
    }


def _write_report(report: Dict[str, Any], bucket: str, prefix: str, kms_key_arn: str) -> Optional[str]:
    """Persist the report to S3 under a date partition. Returns the key, or None."""
    if not bucket:
        LOGGER.info("No report bucket configured; skipping S3 delivery.")
        return None

    generated_at = dt.datetime.fromisoformat(report["generated_at"])
    key = "/".join(
        [
            prefix.strip("/"),
            f"year={generated_at:%Y}",
            f"month={generated_at:%m}",
            f"day={generated_at:%d}",
            f"compliance-report-{generated_at:%Y%m%dT%H%M%SZ}.json",
        ]
    ).lstrip("/")

    request: Dict[str, Any] = {
        "Bucket": bucket,
        "Key": key,
        "Body": json.dumps(report, indent=2, sort_keys=True).encode("utf-8"),
        "ContentType": "application/json",
    }

    if kms_key_arn:
        request["ServerSideEncryption"] = "aws:kms"
        request["SSEKMSKeyId"] = kms_key_arn
    else:
        request["ServerSideEncryption"] = "AES256"

    _client("s3").put_object(**request)
    LOGGER.info("Wrote compliance report to s3://%s/%s", bucket, key)
    return key


def _format_summary(report: Dict[str, Any], max_resources: int) -> str:
    """Render the human-readable digest published to the topic."""
    totals = report["totals"]
    lines = [
        "Fleet compliance summary",
        f"Generated: {report['generated_at']}",
        "",
        f"Compliant nodes: {totals['compliant_count']} ({totals['compliant_percent']}%)",
        f"Non-compliant nodes: {totals['non_compliant_count']}",
        "",
        "By compliance type:",
    ]

    if report["compliance_types"]:
        for entry in report["compliance_types"]:
            lines.append(
                f"  {entry['compliance_type']}: {entry['non_compliant_count']} non-compliant "
                f"of {entry['total_count']} ({entry['compliant_percent']}% compliant)"
            )
    else:
        lines.append("  no compliance data reported")

    severities = ", ".join(report["reported_severities"])
    lines.extend(["", f"Non-compliant resources at severity {severities}: {report['reported_resource_count']}"])

    for finding in report["non_compliant_resources"][:max_resources]:
        lines.append(
            f"  [{finding['overall_severity']}] {finding['resource_id']} "
            f"({finding['compliance_type']}): {finding['non_compliant_count']} item(s)"
        )

    remaining = report["reported_resource_count"] - max_resources
    if remaining > 0:
        lines.append(f"  ... and {remaining} more; full detail is in the report object.")

    return "\n".join(lines)


def _publish_summary(report: Dict[str, Any], topic_arn: str, max_resources: int) -> bool:
    """Publish the digest to SNS. Returns whether a message was sent."""
    if not topic_arn:
        LOGGER.info("No topic configured; skipping notification.")
        return False

    _client("sns").publish(
        TopicArn=topic_arn,
        Subject=f"Fleet compliance: {report['totals']['non_compliant_count']} non-compliant node(s)"[:100],
        Message=_format_summary(report, max_resources),
    )
    return True


def handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:  # noqa: ARG001 - Lambda signature
    """Entry point. Collects compliance state, persists it, and publishes a digest."""
    bucket = os.environ.get("REPORT_BUCKET", "")
    prefix = os.environ.get("REPORT_PREFIX", "compliance-reports")
    topic_arn = os.environ.get("SNS_TOPIC_ARN", "")
    kms_key_arn = os.environ.get("REPORT_KMS_KEY_ARN", "")
    max_resources = _int_env("MAX_RESOURCES_IN_SUMMARY", 25)
    report_severities = _parse_csv_env("REPORT_SEVERITIES", DEFAULT_REPORT_SEVERITIES)

    LOGGER.info("Summarising fleet compliance at severities %s", ",".join(report_severities))

    report = _build_report(report_severities)
    report_key = _write_report(report, bucket, prefix, kms_key_arn)
    notified = _publish_summary(report, topic_arn, max_resources)

    LOGGER.info(
        "Compliance summary complete: %s non-compliant of %s reported nodes.",
        report["totals"]["non_compliant_count"],
        report["totals"]["compliant_count"] + report["totals"]["non_compliant_count"],
    )

    return {
        "generated_at": report["generated_at"],
        "compliant_count": report["totals"]["compliant_count"],
        "non_compliant_count": report["totals"]["non_compliant_count"],
        "reported_resource_count": report["reported_resource_count"],
        "report_bucket": bucket or None,
        "report_key": report_key,
        "notified": notified,
    }
