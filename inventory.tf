# Fleet inventory: what is actually running out there.
#
# Patching and convergence act on the fleet. Inventory answers the prior question — what
# software, services, network configuration and compliance state each managed node
# reports — and lands that answer somewhere durable and queryable.
#
# Two pieces:
#   1. an inventory association that tells every targeted node WHAT to collect and how
#      often. Systems Manager permits exactly one inventory association per node, so this
#      is modelled as a single dedicated association rather than as one entry among the
#      general convergence associations;
#   2. a resource data sync that continuously flattens inventory and compliance data from
#      the Systems Manager service into S3, where it outlives the 30-day console window
#      and can be read by Athena, Glue, or anything else that reads JSON on S3.

locals {
  # The inventory document takes "Enabled" / "Disabled" strings. Modelling the collection
  # surface as booleans keeps the caller-facing configuration typed, and the conversion
  # happens once, here.
  inventory_toggles = {
    applications                = var.inventory_collection.applications
    awsComponents               = var.inventory_collection.aws_components
    billingInfo                 = var.inventory_collection.billing_info
    customInventory             = var.inventory_collection.custom_inventory
    instanceDetailedInformation = var.inventory_collection.instance_detailed_information
    networkConfig               = var.inventory_collection.network_config
    services                    = var.inventory_collection.services
    windowsRoles                = var.inventory_collection.windows_roles
    windowsUpdates              = var.inventory_collection.windows_updates
  }

  inventory_parameters = merge(
    { for name, enabled in local.inventory_toggles : name => enabled ? "Enabled" : "Disabled" },
    # File and registry collection are described as JSON documents rather than a flag, and
    # are only sent when the caller has actually declared something to collect. An empty
    # string is a valid "collect nothing" value for both.
    var.inventory_collection.files == null ? {} : { files = var.inventory_collection.files },
    var.inventory_collection.windows_registry == null ? {} : { windowsRegistry = var.inventory_collection.windows_registry },
  )

  # The sync bucket is created here unless the caller points at an existing one.
  create_inventory_bucket = var.enable_resource_data_sync && var.inventory_sync_bucket_name == null
  create_inventory_kms    = local.create_inventory_bucket && var.create_inventory_sync_kms_key

  inventory_bucket_name = (
    var.inventory_sync_bucket_name != null
    ? var.inventory_sync_bucket_name
    : "${var.name_prefix}-ssm-inventory-${data.aws_caller_identity.current.account_id}-${var.aws_region}"
  )

  # A caller-supplied key wins; otherwise the module key is used when one was created.
  inventory_kms_key_arn = try(
    coalesce(var.inventory_sync_kms_key_arn, one(aws_kms_key.inventory[*].arn)),
    null,
  )

  inventory_sync_prefix = trimsuffix(var.inventory_sync_key_prefix, "/")
}

################################################################################
# Inventory collection
################################################################################

# AWS-GatherSoftwareInventory is an AWS-managed document; the association below is what
# actually schedules it against the fleet. Only one inventory association may apply to a
# given node, so targeting is deliberately kept to a single declaration.
resource "aws_ssm_association" "inventory" {
  count = var.enable_inventory ? 1 : 0

  name             = "AWS-GatherSoftwareInventory"
  association_name = "${var.name_prefix}-inventory"

  schedule_expression = var.inventory_schedule_expression

  compliance_severity = var.inventory_compliance_severity
  sync_compliance     = "AUTO"

  parameters = local.inventory_parameters

  dynamic "targets" {
    for_each = var.inventory_targets

    content {
      key    = targets.value.key
      values = targets.value.values
    }
  }

  lifecycle {
    precondition {
      condition = anytrue([
        for enabled in values(local.inventory_toggles) : enabled
      ])
      error_message = "Inventory is enabled but every collection category is switched off. Enable at least one category or set enable_inventory = false."
    }
  }
}

################################################################################
# Sync destination encryption
################################################################################

data "aws_iam_policy_document" "inventory_kms" {
  count = local.create_inventory_kms ? 1 : 0

  statement {
    sid       = "AllowAccountAdministration"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  # The sync writes on behalf of Systems Manager, so the service itself must be able to
  # use the key. Scoped to this account so another account's Systems Manager cannot.
  statement {
    sid    = "AllowSystemsManagerSyncEncryption"
    effect = "Allow"

    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:Encrypt",
      "kms:GenerateDataKey",
      "kms:GenerateDataKey*",
      "kms:ReEncrypt*",
    ]

    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["ssm.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_kms_key" "inventory" {
  count = local.create_inventory_kms ? 1 : 0

  description             = "Encrypts Systems Manager inventory and compliance data synced to S3."
  deletion_window_in_days = var.inventory_kms_key_deletion_window_days
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.inventory_kms[0].json

  tags = {
    Name = "${var.name_prefix}-ssm-inventory"
  }
}

resource "aws_kms_alias" "inventory" {
  count = local.create_inventory_kms ? 1 : 0

  name          = "alias/${var.name_prefix}-ssm-inventory"
  target_key_id = aws_kms_key.inventory[0].key_id
}

################################################################################
# Sync destination bucket
################################################################################

resource "aws_s3_bucket" "inventory" {
  count = local.create_inventory_bucket ? 1 : 0

  bucket = local.inventory_bucket_name

  tags = {
    Name = local.inventory_bucket_name
  }
}

# ACLs disabled: the bucket owner owns every object regardless of who wrote it.
resource "aws_s3_bucket_ownership_controls" "inventory" {
  count = local.create_inventory_bucket ? 1 : 0

  bucket = aws_s3_bucket.inventory[0].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "inventory" {
  count = local.create_inventory_bucket ? 1 : 0

  bucket = aws_s3_bucket.inventory[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "inventory" {
  count = local.create_inventory_bucket ? 1 : 0

  bucket = aws_s3_bucket.inventory[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "inventory" {
  count = local.create_inventory_bucket ? 1 : 0

  bucket = aws_s3_bucket.inventory[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = local.inventory_kms_key_arn != null ? "aws:kms" : "AES256"
      kms_master_key_id = local.inventory_kms_key_arn
    }

    # Cuts KMS request volume on a bucket that receives a continuous stream of small
    # inventory objects.
    bucket_key_enabled = local.inventory_kms_key_arn != null
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "inventory" {
  count = local.create_inventory_bucket ? 1 : 0

  bucket = aws_s3_bucket.inventory[0].id

  rule {
    id     = "expire-inventory-data"
    status = "Enabled"

    filter {}

    expiration {
      days = var.inventory_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = var.inventory_noncurrent_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.inventory]
}

data "aws_iam_policy_document" "inventory_bucket" {
  count = local.create_inventory_bucket ? 1 : 0

  statement {
    sid       = "DenyNonTlsTraffic"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.inventory[0].arn, "${aws_s3_bucket.inventory[0].arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # The resource data sync checks the bucket ACL before it starts writing.
  statement {
    sid       = "AllowSystemsManagerBucketCheck"
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.inventory[0].arn]

    principals {
      type        = "Service"
      identifiers = ["ssm.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  # Writes are confined to this account's partition of the sync prefix. The
  # bucket-owner-full-control condition is the canned ACL Systems Manager sends, and
  # remains accepted while object ownership is enforced.
  statement {
    sid       = "AllowSystemsManagerSyncDelivery"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.inventory[0].arn}/${local.inventory_sync_prefix}/*/accountid=${data.aws_caller_identity.current.account_id}/*"]

    principals {
      type        = "Service"
      identifiers = ["ssm.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_s3_bucket_policy" "inventory" {
  count = local.create_inventory_bucket ? 1 : 0

  bucket = aws_s3_bucket.inventory[0].id
  policy = data.aws_iam_policy_document.inventory_bucket[0].json

  # Applying the policy before public access is blocked would briefly leave the bucket
  # governed by a policy with a wildcard principal statement.
  depends_on = [aws_s3_bucket_public_access_block.inventory]
}

################################################################################
# Resource data sync
################################################################################

# Inventory data lives in the Systems Manager service for a limited window. The sync
# copies it out continuously so fleet history survives, and so that inventory and
# compliance can be queried with ordinary data tools rather than through the API.
resource "aws_ssm_resource_data_sync" "inventory" {
  count = var.enable_resource_data_sync ? 1 : 0

  name = "${var.name_prefix}-inventory-sync"

  s3_destination {
    bucket_name = local.inventory_bucket_name
    prefix      = local.inventory_sync_prefix
    region      = var.aws_region
    sync_format = "JsonSerDe"
    kms_key_arn = local.inventory_kms_key_arn
  }

  # The bucket policy is what grants the sync its write permission, so it has to be in
  # place before the sync is created or the sync fails validation.
  depends_on = [
    aws_s3_bucket_policy.inventory,
    aws_s3_bucket_public_access_block.inventory,
  ]

  lifecycle {
    precondition {
      condition     = var.inventory_sync_bucket_name != null || local.create_inventory_bucket
      error_message = "A resource data sync needs a destination bucket. Either let this configuration create one or set inventory_sync_bucket_name."
    }
  }
}
