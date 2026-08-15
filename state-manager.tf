# Configuration convergence for the managed-node fleet.
#
# Two things live here:
#   1. every Command document in documents/ is published to Systems Manager, so a
#      document is added to the fleet by adding a file rather than by editing Terraform;
#   2. State Manager associations bind those documents, and AWS-managed ones, to a
#      tag-selected slice of the fleet on a schedule.
#
# Associations are the standing state of the fleet: a maintenance window patches on a
# cadence, whereas an association keeps re-asserting a declared state and reports a node
# that has drifted away from it as non-compliant.

locals {
  # Documents are discovered from disk. The published name is derived from the file name,
  # so documents/service-convergence.yml becomes <prefix>-service-convergence.
  fleet_documents = {
    for document_file in fileset("${path.module}/documents", "*.yml") :
    trimsuffix(document_file, ".yml") => {
      file_name = document_file
      content   = file("${path.module}/documents/${document_file}")
    }
  }

  # An association described with enabled = false is kept in configuration but not
  # created, so a convergence document can ship ready to adopt without being switched on.
  enabled_associations = {
    for key, association in var.state_manager_associations : key => association
    if association.enabled
  }

  association_output_enabled = var.association_output_s3_bucket != null
}

################################################################################
# Command documents
################################################################################

resource "aws_ssm_document" "fleet" {
  for_each = local.fleet_documents

  name            = "${var.name_prefix}-${each.key}"
  document_type   = "Command"
  document_format = "YAML"
  target_type     = var.document_target_type
  content         = each.value.content

  tags = {
    Name       = "${var.name_prefix}-${each.key}"
    SourceFile = each.value.file_name
  }
}

################################################################################
# State Manager associations
################################################################################

resource "aws_ssm_association" "this" {
  for_each = local.enabled_associations

  # A local document is referenced through the resource so the association is rebuilt
  # when the document content changes; try keeps the expression evaluable while the
  # precondition below reports a key that does not resolve.
  name = (
    each.value.local_document != null
    ? try(aws_ssm_document.fleet[each.value.local_document].name, "")
    : each.value.document_name
  )

  association_name = coalesce(each.value.association_name, "${var.name_prefix}-${each.key}")
  document_version = each.value.document_version

  schedule_expression         = each.value.schedule_expression
  apply_only_at_cron_interval = each.value.apply_only_at_cron_interval

  compliance_severity = each.value.compliance_severity
  sync_compliance     = each.value.sync_compliance

  # The same rate limiting the patch windows use: a document that fails against the fleet
  # stops inside the error budget rather than sweeping every node.
  max_concurrency = each.value.max_concurrency
  max_errors      = each.value.max_errors

  parameters = each.value.parameters

  dynamic "targets" {
    for_each = each.value.targets

    content {
      key    = targets.value.key
      values = targets.value.values
    }
  }

  # Systems Manager truncates the output it returns inline, so full command output goes
  # to S3 when the caller supplies a bucket.
  dynamic "output_location" {
    for_each = local.association_output_enabled ? [1] : []

    content {
      s3_bucket_name = var.association_output_s3_bucket
      s3_key_prefix  = "${trimsuffix(var.association_output_s3_key_prefix, "/")}/${each.key}"
      s3_region      = var.aws_region
    }
  }

  lifecycle {
    precondition {
      condition = (
        each.value.local_document == null ||
        contains(keys(local.fleet_documents), coalesce(each.value.local_document, ""))
      )
      error_message = "Association references a local document that does not exist in documents/. Add the file or correct local_document."
    }

    precondition {
      condition     = each.value.document_name == null || length(each.value.document_name) > 0
      error_message = "document_name must name a Systems Manager document."
    }
  }
}
