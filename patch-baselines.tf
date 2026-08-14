# Patch management for the managed-node fleet.
#
# The model is deliberately three layered:
#   1. a baseline decides WHICH patches are approved and when;
#   2. a patch group binds a slice of the fleet (a "Patch Group" tag value) to one
#      baseline per operating system;
#   3. a maintenance window decides WHEN that slice is patched, and how fast.
#
# Nothing here references an instance ID, so the fleet can scale freely.

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  # Flattened baseline x patch-group pairs, keyed so a group can be traced back to the
  # baseline that governs it.
  patch_group_bindings = merge([
    for baseline_key, baseline in var.patch_baselines : {
      for group in baseline.patch_groups :
      "${baseline_key}/${group}" => {
        baseline_key = baseline_key
        patch_group  = group
      }
    }
  ]...)

  # Every patch group declared across all baselines, used to validate that each
  # maintenance window targets a group that actually exists.
  declared_patch_groups = distinct(flatten([
    for baseline in var.patch_baselines : baseline.patch_groups
  ]))

  # A patch group may only be attached to a single baseline per operating system.
  # Collect the (operating system, group) pairs so the duplicate check below is exact.
  os_group_pairs = flatten([
    for baseline in var.patch_baselines : [
      for group in baseline.patch_groups : "${baseline.operating_system}/${group}"
    ]
  ])

  baselines_set_as_default = {
    for key, baseline in var.patch_baselines : key => baseline
    if baseline.set_as_default
  }

  maintenance_window_role_arn = coalesce(
    var.maintenance_window_role_arn,
    one(aws_iam_role.maintenance_window[*].arn),
  )

  patch_log_group_name = "/aws/ssm/${var.name_prefix}/patch"
}

################################################################################
# Baselines
################################################################################

resource "aws_ssm_patch_baseline" "this" {
  for_each = var.patch_baselines

  name             = "${var.name_prefix}-${each.key}"
  description      = coalesce(each.value.description, "Patch baseline for ${each.value.operating_system} nodes.")
  operating_system = each.value.operating_system

  # Patches listed explicitly bypass the approval rules entirely, in both directions.
  approved_patches        = each.value.approved_patches
  rejected_patches        = each.value.rejected_patches
  rejected_patches_action = each.value.rejected_patches_action

  dynamic "approval_rule" {
    for_each = each.value.approval_rules

    content {
      # Exactly one of these is set; the variable validation enforces that, and the
      # provider ignores the null.
      approve_after_days  = approval_rule.value.approve_after_days
      approve_until_date  = approval_rule.value.approve_until_date
      compliance_level    = approval_rule.value.compliance_level
      enable_non_security = approval_rule.value.enable_non_security

      dynamic "patch_filter" {
        for_each = approval_rule.value.patch_filters

        content {
          key    = patch_filter.key
          values = patch_filter.value
        }
      }
    }
  }

  tags = {
    Name            = "${var.name_prefix}-${each.key}"
    OperatingSystem = each.value.operating_system
  }

  lifecycle {
    precondition {
      condition     = length(local.os_group_pairs) == length(distinct(local.os_group_pairs))
      error_message = "A patch group may only be attached to one baseline per operating system. Remove the duplicate binding."
    }
  }
}

# Binds a slice of the fleet, identified by its "Patch Group" tag value, to a baseline.
resource "aws_ssm_patch_group" "this" {
  for_each = local.patch_group_bindings

  baseline_id = aws_ssm_patch_baseline.this[each.value.baseline_key].id
  patch_group = each.value.patch_group
}

# Makes a baseline the account default for its operating system, so any node that is not
# explicitly bound to a patch group still patches against a reviewed baseline rather than
# the AWS-managed default.
resource "aws_ssm_default_patch_baseline" "this" {
  for_each = local.baselines_set_as_default

  baseline_id      = aws_ssm_patch_baseline.this[each.key].id
  operating_system = each.value.operating_system
}

################################################################################
# Maintenance window service role
################################################################################

data "aws_iam_policy_document" "maintenance_window_assume" {
  count = var.maintenance_window_role_arn == null ? 1 : 0

  statement {
    sid     = "AllowSsmMaintenanceWindowAssume"
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

resource "aws_iam_role" "maintenance_window" {
  count = var.maintenance_window_role_arn == null ? 1 : 0

  name               = "${var.name_prefix}-maintenance-window"
  description        = "Service role Systems Manager assumes to run maintenance window tasks."
  assume_role_policy = data.aws_iam_policy_document.maintenance_window_assume[0].json

  tags = {
    Name = "${var.name_prefix}-maintenance-window"
  }
}

resource "aws_iam_role_policy_attachment" "maintenance_window" {
  count = var.maintenance_window_role_arn == null ? 1 : 0

  role       = aws_iam_role.maintenance_window[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonSSMMaintenanceWindowRole"
}

################################################################################
# Patch command output
################################################################################

resource "aws_cloudwatch_log_group" "patch" {
  name              = local.patch_log_group_name
  retention_in_days = var.patch_log_retention_days
  kms_key_id        = var.patch_log_kms_key_arn

  tags = {
    Name = local.patch_log_group_name
  }
}

################################################################################
# Maintenance windows
################################################################################

resource "aws_ssm_maintenance_window" "this" {
  for_each = var.maintenance_windows

  name                       = "${var.name_prefix}-${each.key}"
  description                = coalesce(each.value.description, "Patch ${each.value.operation} window for ${each.value.patch_group}.")
  schedule                   = each.value.schedule
  schedule_timezone          = each.value.schedule_timezone
  duration                   = each.value.duration
  cutoff                     = each.value.cutoff
  enabled                    = each.value.enabled
  allow_unassociated_targets = false

  tags = {
    Name       = "${var.name_prefix}-${each.key}"
    PatchGroup = each.value.patch_group
    Operation  = each.value.operation
  }

  lifecycle {
    precondition {
      condition     = contains(local.declared_patch_groups, each.value.patch_group)
      error_message = "Maintenance window targets a patch group that no baseline declares. Add the group to a baseline first."
    }
  }
}

# Targets the window at the patch group tag, plus any additional tag scoping the caller
# supplies (for example an Environment tag) so a window can be narrowed further.
resource "aws_ssm_maintenance_window_target" "this" {
  for_each = var.maintenance_windows

  window_id     = aws_ssm_maintenance_window.this[each.key].id
  name          = "${var.name_prefix}-${each.key}"
  description   = "Managed nodes tagged into the ${each.value.patch_group} patch group."
  resource_type = "INSTANCE"

  targets {
    key    = "tag:${var.patch_group_tag_key}"
    values = [each.value.patch_group]
  }

  dynamic "targets" {
    for_each = each.value.resource_tag_scope

    content {
      key    = "tag:${targets.key}"
      values = [targets.value]
    }
  }
}

resource "aws_ssm_maintenance_window_task" "patch" {
  for_each = var.maintenance_windows

  window_id        = aws_ssm_maintenance_window.this[each.key].id
  name             = "${var.name_prefix}-${each.key}-patch"
  description      = "Runs AWS-RunPatchBaseline against the ${each.value.patch_group} patch group."
  task_type        = "RUN_COMMAND"
  task_arn         = "AWS-RunPatchBaseline"
  priority         = each.value.priority
  service_role_arn = local.maintenance_window_role_arn

  # A concurrency ceiling and an error budget together mean a bad patch stops early
  # instead of rolling across the whole group.
  max_concurrency = each.value.max_concurrency
  max_errors      = each.value.max_errors

  cutoff_behavior = "CANCEL_TASK"

  targets {
    key    = "WindowTargetIds"
    values = [aws_ssm_maintenance_window_target.this[each.key].id]
  }

  task_invocation_parameters {
    run_command_parameters {
      document_version = "$DEFAULT"
      timeout_seconds  = 3600

      cloudwatch_config {
        cloudwatch_log_group_name = aws_cloudwatch_log_group.patch.name
        cloudwatch_output_enabled = true
      }

      parameter {
        name   = "Operation"
        values = [each.value.operation]
      }

      parameter {
        name   = "RebootOption"
        values = [each.value.reboot_option]
      }
    }
  }
}
