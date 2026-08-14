output "patch_baseline_ids" {
  description = "Patch baseline IDs keyed by baseline name."
  value       = { for key, baseline in aws_ssm_patch_baseline.this : key => baseline.id }
}

output "patch_baseline_arns" {
  description = "Patch baseline ARNs keyed by baseline name."
  value       = { for key, baseline in aws_ssm_patch_baseline.this : key => baseline.arn }
}

output "patch_groups" {
  description = "Patch group tag values a managed node can carry, keyed by baseline and group."
  value       = { for key, binding in local.patch_group_bindings : key => binding.patch_group }
}

output "default_patch_baselines" {
  description = "Operating systems for which a baseline in this configuration is the account default."
  value       = { for key, baseline in local.baselines_set_as_default : key => baseline.operating_system }
}

output "maintenance_window_ids" {
  description = "Maintenance window IDs keyed by window name."
  value       = { for key, window in aws_ssm_maintenance_window.this : key => window.id }
}

output "maintenance_window_task_ids" {
  description = "Patch task IDs keyed by maintenance window name."
  value       = { for key, task in aws_ssm_maintenance_window_task.patch : key => task.window_task_id }
}

output "maintenance_window_role_arn" {
  description = "Service role Systems Manager assumes to run maintenance window tasks."
  value       = local.maintenance_window_role_arn
}

output "patch_log_group_name" {
  description = "CloudWatch log group that captures patch command output."
  value       = aws_cloudwatch_log_group.patch.name
}
