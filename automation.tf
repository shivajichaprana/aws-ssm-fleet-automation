# Operational runbooks for the managed-node fleet.
#
# Associations and maintenance windows cover what the fleet does on a schedule. Runbooks
# cover the rest: the patch that cannot wait for Saturday, the node that stopped
# converging, the hardening baseline that ships switched off and is adopted deliberately.
#
# Each runbook is an Automation document in automation/, published the same way Command
# documents are — by dropping a file in a directory. Writing them down as documents rather
# than as shell history is what makes an operational procedure reviewable, repeatable, and
# runnable by somebody who was not there the first time.
#
# The role below is what Automation assumes while a runbook runs. It is deliberately
# narrow: commands may only be sent to nodes that carry the fleet's patch-group tag, and
# only using the fleet's own documents or the AWS patch document.

locals {
  automation_enabled = var.enable_automation_runbooks

  # Runbooks are discovered from disk, so automation/patch-on-demand.yml is published as
  # <prefix>-patch-on-demand without any Terraform change.
  automation_runbooks = {
    for runbook_file in fileset("${path.module}/automation", "*.yml") :
    trimsuffix(runbook_file, ".yml") => {
      file_name = runbook_file
      content   = file("${path.module}/automation/${runbook_file}")
    }
  }

  create_automation_role = local.automation_enabled && var.automation_role_arn == null

  automation_role_arn = try(
    coalesce(var.automation_role_arn, one(aws_iam_role.automation[*].arn)),
    null,
  )

  automation_output_prefix = var.automation_output_s3_bucket == null ? null : "arn:${data.aws_partition.current.partition}:s3:::${var.automation_output_s3_bucket}/*"
}

################################################################################
# Runbooks
################################################################################

resource "aws_ssm_document" "automation" {
  for_each = local.automation_enabled ? local.automation_runbooks : {}

  name            = "${var.name_prefix}-${each.key}"
  document_type   = "Automation"
  document_format = "YAML"
  content         = each.value.content

  tags = {
    Name       = "${var.name_prefix}-${each.key}"
    SourceFile = each.value.file_name
  }
}

################################################################################
# Execution role
################################################################################

data "aws_iam_policy_document" "automation_assume" {
  count = local.create_automation_role ? 1 : 0

  statement {
    sid     = "AllowSsmAutomationAssume"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ssm.amazonaws.com"]
    }

    # Confused-deputy guard: only this account's Systems Manager may assume the role.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

data "aws_iam_policy_document" "automation" {
  count = local.create_automation_role ? 1 : 0

  # Commands may only be sent to nodes that are part of the fleet, which here means nodes
  # carrying the patch-group tag. An untagged node is outside the fleet model and is not
  # reachable through a runbook.
  statement {
    sid       = "AllowSendCommandToFleetNodes"
    effect    = "Allow"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*"]

    condition {
      test     = "StringLike"
      variable = "ssm:resourceTag/${var.patch_group_tag_key}"
      values   = ["*"]
    }
  }

  # And only through the fleet's own documents or the AWS patch document, so a runbook
  # cannot be edited into a general-purpose remote shell.
  statement {
    sid     = "AllowSendCommandWithFleetDocuments"
    effect  = "Allow"
    actions = ["ssm:SendCommand"]

    resources = [
      "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:document/${var.name_prefix}-*",
      "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}::document/AWS-RunPatchBaseline",
      "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}::document/AWS-UpdateSSMAgent",
    ]
  }

  # Reading back what a command did, and what Systems Manager knows about the fleet.
  # These calls do not support resource-level permissions.
  statement {
    sid    = "AllowCommandAndFleetReads"
    effect = "Allow"

    actions = [
      "ec2:DescribeInstances",
      "ssm:DescribeAutomationExecutions",
      "ssm:DescribeInstanceInformation",
      "ssm:DescribeInstancePatchStates",
      "ssm:DescribeInstancePatchStatesForPatchGroup",
      "ssm:DescribeInstancePatches",
      "ssm:GetAutomationExecution",
      "ssm:GetCommandInvocation",
      "ssm:ListCommandInvocations",
      "ssm:ListCommands",
    ]

    resources = ["*"]
  }

  # Cancelling a command the runbook itself started is part of stopping a bad run.
  statement {
    sid       = "AllowCancelCommand"
    effect    = "Allow"
    actions   = ["ssm:CancelCommand"]
    resources = ["arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"]
  }

  # Approval notifications, granted only for the topic the caller nominated.
  dynamic "statement" {
    for_each = var.automation_approval_topic_arn == null ? [] : [1]

    content {
      sid       = "AllowApprovalNotifications"
      effect    = "Allow"
      actions   = ["sns:Publish"]
      resources = [var.automation_approval_topic_arn]
    }
  }

  # Full command output, granted only for the bucket the caller nominated.
  dynamic "statement" {
    for_each = local.automation_output_prefix == null ? [] : [1]

    content {
      sid       = "AllowCommandOutputDelivery"
      effect    = "Allow"
      actions   = ["s3:PutObject"]
      resources = [local.automation_output_prefix]
    }
  }
}

resource "aws_iam_role" "automation" {
  count = local.create_automation_role ? 1 : 0

  name               = "${var.name_prefix}-automation"
  description        = "Role Systems Manager Automation assumes to run the fleet runbooks."
  assume_role_policy = data.aws_iam_policy_document.automation_assume[0].json

  tags = {
    Name = "${var.name_prefix}-automation"
  }
}

resource "aws_iam_role_policy" "automation" {
  count = local.create_automation_role ? 1 : 0

  name   = "${var.name_prefix}-automation"
  role   = aws_iam_role.automation[0].id
  policy = data.aws_iam_policy_document.automation[0].json
}
