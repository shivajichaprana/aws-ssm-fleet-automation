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

output "ssm_document_names" {
  description = "Published Command document names keyed by the file that defines them."
  value       = { for key, document in aws_ssm_document.fleet : key => document.name }
}

output "ssm_document_arns" {
  description = "Published Command document ARNs keyed by the file that defines them."
  value       = { for key, document in aws_ssm_document.fleet : key => document.arn }
}

output "state_manager_association_ids" {
  description = "State Manager association IDs keyed by association name."
  value       = { for key, association in aws_ssm_association.this : key => association.association_id }
}

output "state_manager_association_documents" {
  description = "Document each created association runs, keyed by association name."
  value       = { for key, association in aws_ssm_association.this : key => association.name }
}

output "described_associations_not_created" {
  description = "Associations present in configuration but switched off, so they are not created."
  value       = sort(setsubtract(keys(var.state_manager_associations), keys(local.enabled_associations)))
}

output "inventory_association_id" {
  description = "State Manager association that schedules inventory collection, null when inventory is disabled."
  value       = one(aws_ssm_association.inventory[*].association_id)
}

output "inventory_collection_categories" {
  description = "Inventory categories currently switched on."
  value       = sort([for name, enabled in local.inventory_toggles : name if enabled])
}

output "inventory_sync_name" {
  description = "Resource data sync that copies inventory and compliance data to S3."
  value       = one(aws_ssm_resource_data_sync.inventory[*].name)
}

output "inventory_sync_bucket" {
  description = "Bucket that receives synced inventory data, whether created here or supplied."
  value       = var.enable_resource_data_sync ? local.inventory_bucket_name : null
}

output "inventory_sync_prefix" {
  description = "Key prefix under which synced inventory data lands."
  value       = local.inventory_sync_prefix
}

output "inventory_sync_kms_key_arn" {
  description = "Key encrypting synced inventory data, null when the bucket uses S3-managed encryption."
  value       = local.inventory_kms_key_arn
}

output "compliance_report_function_name" {
  description = "Read-only function that produces the fleet compliance digest."
  value       = one(aws_lambda_function.compliance_reporter[*].function_name)
}

output "compliance_topic_arn" {
  description = "Topic that receives the fleet compliance digest."
  value       = one(aws_sns_topic.compliance[*].arn)
}

output "compliance_report_location" {
  description = "Bucket and prefix where compliance report objects are written, null when reports are notification only."
  value       = local.compliance_report_to_s3 ? {
    bucket = local.compliance_report_bucket
    prefix = local.compliance_report_prefix
  } : null
}
