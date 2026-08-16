# Compliance summarisation for the managed-node fleet.
#
# Inventory and the resource data sync make fleet state durable and queryable. This layer
# answers the narrower operational question on a cadence: which nodes are currently out of
# compliance, on what, and how badly.
#
# The reporter is read only by construction — it lists compliance state, writes its own
# report object, and publishes a digest. Remediation stays a deliberate act: a maintenance
# window that installs patches, or an association that is switched on after review.

locals {
  compliance_enabled = var.enable_compliance_reporting

  # Reports land in the inventory bucket by default so fleet data lives in one place, but
  # a caller who brought their own sync bucket can point reports somewhere writable.
  compliance_report_bucket = try(
    coalesce(var.compliance_report_s3_bucket, one(aws_s3_bucket.inventory[*].id)),
    "",
  )

  compliance_report_prefix  = trimsuffix(var.compliance_report_key_prefix, "/")
  compliance_report_to_s3   = local.compliance_enabled && local.compliance_report_bucket != ""
  compliance_function_name  = "${var.name_prefix}-compliance-reporter"
  compliance_log_group_name = "/aws/lambda/${var.name_prefix}-compliance-reporter"

  # Reports written to the module-managed bucket inherit the inventory key; a caller who
  # redirected reports to their own bucket supplies the key that bucket expects.
  compliance_report_kms_key = (
    local.compliance_report_to_s3
    ? (var.compliance_report_s3_bucket == null ? local.inventory_kms_key_arn : var.compliance_report_kms_key_arn)
    : null
  )

  compliance_topic_subscribed = local.compliance_enabled ? var.compliance_notification_emails : []
}

################################################################################
# Notification topic
################################################################################

data "aws_iam_policy_document" "compliance_topic" {
  count = local.compliance_enabled ? 1 : 0

  statement {
    sid       = "AllowAccountPublish"
    effect    = "Allow"
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.compliance[0].arn]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceOwner"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_sns_topic" "compliance" {
  count = local.compliance_enabled ? 1 : 0

  name = "${var.name_prefix}-fleet-compliance"

  # The AWS-managed SNS key keeps the topic encrypted without making every subscriber
  # depend on a customer managed key policy.
  kms_master_key_id = "alias/aws/sns"

  tags = {
    Name = "${var.name_prefix}-fleet-compliance"
  }
}

resource "aws_sns_topic_policy" "compliance" {
  count = local.compliance_enabled ? 1 : 0

  arn    = aws_sns_topic.compliance[0].arn
  policy = data.aws_iam_policy_document.compliance_topic[0].json
}

resource "aws_sns_topic_subscription" "compliance_email" {
  for_each = toset(local.compliance_topic_subscribed)

  topic_arn = aws_sns_topic.compliance[0].arn
  protocol  = "email"
  endpoint  = each.value
}

################################################################################
# Reporter execution role
################################################################################

data "aws_iam_policy_document" "compliance_reporter_assume" {
  count = local.compliance_enabled ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "compliance_reporter" {
  count = local.compliance_enabled ? 1 : 0

  # Compliance list calls are not resource scopable, so they are granted on "*" and the
  # blast radius is held down by the fact that every one of them is read only.
  statement {
    sid    = "ReadComplianceState"
    effect = "Allow"

    actions = [
      "ssm:ListComplianceItems",
      "ssm:ListComplianceSummaries",
      "ssm:ListResourceComplianceSummaries",
      "ssm:DescribeInstanceInformation",
      "ssm:DescribeInstancePatchStates",
    ]

    resources = ["*"]
  }

  statement {
    sid       = "WriteLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:${local.compliance_log_group_name}:*"]
  }

  statement {
    sid       = "PublishSummary"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.compliance[0].arn]
  }

  dynamic "statement" {
    for_each = local.compliance_report_to_s3 ? [1] : []

    content {
      sid       = "WriteReportObject"
      effect    = "Allow"
      actions   = ["s3:PutObject"]
      resources = ["arn:${data.aws_partition.current.partition}:s3:::${local.compliance_report_bucket}/${local.compliance_report_prefix}/*"]
    }
  }

  dynamic "statement" {
    for_each = local.compliance_report_kms_key != null ? [1] : []

    content {
      sid       = "UseReportKey"
      effect    = "Allow"
      actions   = ["kms:Decrypt", "kms:DescribeKey", "kms:Encrypt", "kms:GenerateDataKey"]
      resources = [local.compliance_report_kms_key]
    }
  }
}

resource "aws_iam_role" "compliance_reporter" {
  count = local.compliance_enabled ? 1 : 0

  name               = "${var.name_prefix}-compliance-reporter"
  description        = "Execution role for the read-only fleet compliance reporter."
  assume_role_policy = data.aws_iam_policy_document.compliance_reporter_assume[0].json

  tags = {
    Name = "${var.name_prefix}-compliance-reporter"
  }
}

resource "aws_iam_role_policy" "compliance_reporter" {
  count = local.compliance_enabled ? 1 : 0

  name   = "compliance-reporter"
  role   = aws_iam_role.compliance_reporter[0].id
  policy = data.aws_iam_policy_document.compliance_reporter[0].json
}

################################################################################
# Reporter function
################################################################################

data "archive_file" "compliance_reporter" {
  count = local.compliance_enabled ? 1 : 0

  type        = "zip"
  source_dir  = "${path.module}/lambda/compliance-reporter"
  output_path = "${path.module}/.terraform/compliance-reporter.zip"
  excludes    = ["README.md", "requirements.txt", "__pycache__"]
}

resource "aws_cloudwatch_log_group" "compliance_reporter" {
  count = local.compliance_enabled ? 1 : 0

  name              = local.compliance_log_group_name
  retention_in_days = var.compliance_log_retention_days
  kms_key_id        = var.compliance_log_kms_key_arn

  tags = {
    Name = local.compliance_log_group_name
  }
}

resource "aws_lambda_function" "compliance_reporter" {
  count = local.compliance_enabled ? 1 : 0

  function_name = local.compliance_function_name
  description   = "Summarises Systems Manager fleet compliance and publishes a digest."
  role          = aws_iam_role.compliance_reporter[0].arn
  handler       = "handler.handler"
  runtime       = "python3.12"
  architectures = ["arm64"]
  timeout       = var.compliance_report_timeout_seconds
  memory_size   = var.compliance_report_memory_mb

  filename         = data.archive_file.compliance_reporter[0].output_path
  source_code_hash = data.archive_file.compliance_reporter[0].output_base64sha256

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      REPORT_BUCKET            = local.compliance_report_to_s3 ? local.compliance_report_bucket : ""
      REPORT_PREFIX            = local.compliance_report_prefix
      REPORT_KMS_KEY_ARN       = local.compliance_report_kms_key == null ? "" : local.compliance_report_kms_key
      SNS_TOPIC_ARN            = aws_sns_topic.compliance[0].arn
      REPORT_SEVERITIES        = join(",", var.compliance_report_severities)
      MAX_RESOURCES_IN_SUMMARY = tostring(var.compliance_max_resources_in_summary)
      LOG_LEVEL                = var.compliance_log_level
    }
  }

  # The log group is created explicitly so its retention and encryption are managed rather
  # than left to the implicit group Lambda would otherwise create.
  depends_on = [
    aws_iam_role_policy.compliance_reporter,
    aws_cloudwatch_log_group.compliance_reporter,
  ]

  tags = {
    Name = local.compliance_function_name
  }
}

################################################################################
# Report schedule
################################################################################

resource "aws_cloudwatch_event_rule" "compliance_report" {
  count = local.compliance_enabled ? 1 : 0

  name                = "${var.name_prefix}-compliance-report"
  description         = "Produces the fleet compliance digest on a schedule."
  schedule_expression = var.compliance_report_schedule_expression

  tags = {
    Name = "${var.name_prefix}-compliance-report"
  }
}

resource "aws_cloudwatch_event_target" "compliance_report" {
  count = local.compliance_enabled ? 1 : 0

  rule      = aws_cloudwatch_event_rule.compliance_report[0].name
  target_id = "compliance-reporter"
  arn       = aws_lambda_function.compliance_reporter[0].arn
}

resource "aws_lambda_permission" "compliance_report" {
  count = local.compliance_enabled ? 1 : 0

  statement_id  = "AllowScheduledComplianceReport"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.compliance_reporter[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.compliance_report[0].arn
}
