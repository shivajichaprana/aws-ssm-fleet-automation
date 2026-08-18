# Interactive access to the fleet.
#
# The point of Session Manager here is to make inbound SSH unnecessary: no bastion, no
# open port 22, no long-lived key material on a node. What replaces them is an
# authenticated, authorised, and recorded session.
#
# Three things make that real, and all three live in this file:
#   1. session preferences, published as a Session document, which decide where the
#      transcript goes, how it is encrypted, and how long a session may live;
#   2. the destinations themselves — a hardened transcript bucket and a streaming log
#      group, both encrypted with a key created here;
#   3. an operator policy that scopes who may connect to which nodes, so access is granted
#      by tag rather than by handing out a shell to the whole fleet.
#
# Session preferences are account-and-region wide. Systems Manager reads the document
# named SSM-SessionManagerRunShell for every session started in the region, which is why
# enable_session_manager exists: a region whose preferences are owned elsewhere should not
# have two configurations fighting over the same document.

locals {
  session_enabled = var.enable_session_manager

  create_session_bucket = local.session_enabled && var.session_log_bucket_name == null

  # A caller-supplied key wins over one created here, and neither is required: with no key
  # at all the transcript bucket falls back to S3-managed encryption and the session
  # itself is protected by transport encryption only.
  create_session_kms = local.session_enabled && var.session_kms_key_arn == null && var.create_session_kms_key

  session_kms_key_arn = try(
    coalesce(var.session_kms_key_arn, one(aws_kms_key.session[*].arn)),
    null,
  )

  session_bucket_name = (
    var.session_log_bucket_name != null
    ? var.session_log_bucket_name
    : "${var.name_prefix}-ssm-sessions-${data.aws_caller_identity.current.account_id}-${var.aws_region}"
  )

  session_log_prefix     = trimsuffix(var.session_log_key_prefix, "/")
  session_log_group_name = "/aws/ssm/${var.name_prefix}/sessions"

  # Streaming to CloudWatch and archiving to S3 answer different questions: the log group
  # is where a session in progress is watched, the bucket is where a session from six
  # months ago is read back. Both are enabled, and both refuse plaintext when a key exists.
  session_preferences = merge(
    {
      s3BucketName                = local.session_enabled ? local.session_bucket_name : ""
      s3KeyPrefix                 = local.session_log_prefix
      s3EncryptionEnabled         = true
      cloudWatchLogGroupName      = local.session_enabled ? local.session_log_group_name : ""
      cloudWatchEncryptionEnabled = local.session_kms_key_arn != null
      cloudWatchStreamingEnabled  = true
      kmsKeyId                    = local.session_kms_key_arn == null ? "" : local.session_kms_key_arn
      idleSessionTimeout          = tostring(var.session_idle_timeout_minutes)
      maxSessionDuration          = tostring(var.session_max_duration_minutes)
      runAsEnabled                = var.session_run_as_enabled
      runAsDefaultUser            = var.session_run_as_enabled ? var.session_run_as_default_user : ""
    },
    # shellProfile is only sent when the caller declared one, so the rendered document
    # stays minimal and a platform with no profile is not sent an empty string.
    length(compact([
      try(var.session_shell_profile.linux, null),
      try(var.session_shell_profile.windows, null),
    ])) == 0 ? {} : {
      shellProfile = {
        for platform, profile in {
          linux   = try(var.session_shell_profile.linux, null)
          windows = try(var.session_shell_profile.windows, null)
        } : platform => profile if profile != null
      }
    },
  )

  session_operator_policy_enabled = local.session_enabled && var.create_session_operator_policy

  # Documents that open a tunnel rather than a recorded shell. Traffic through a forwarded
  # port never appears in the transcript, so they are denied unless explicitly permitted.
  session_tunnel_documents = [
    "AWS-StartPortForwardingSession",
    "AWS-StartPortForwardingSessionToRemoteHost",
    "AWS-StartSSHSession",
  ]
}

################################################################################
# Session encryption
################################################################################

data "aws_iam_policy_document" "session_kms" {
  count = local.create_session_kms ? 1 : 0

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

  # CloudWatch Logs encrypts the streamed session output with this key, and is only
  # permitted to do so for log groups in this account and region.
  statement {
    sid    = "AllowCloudWatchLogsEncryption"
    effect = "Allow"

    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:Encrypt",
      "kms:GenerateDataKey*",
      "kms:ReEncrypt*",
    ]

    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${var.aws_region}.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:*"]
    }
  }

  # Both ends of a session use the key directly: the node encrypts what it sends, the
  # operator decrypts what they receive. Neither is a service principal, so they are
  # granted by role ARN.
  dynamic "statement" {
    for_each = length(var.session_key_user_role_arns) > 0 ? [1] : []

    content {
      sid    = "AllowSessionParticipantsKeyUse"
      effect = "Allow"

      actions = [
        "kms:Decrypt",
        "kms:DescribeKey",
        "kms:Encrypt",
        "kms:GenerateDataKey*",
      ]

      resources = ["*"]

      principals {
        type        = "AWS"
        identifiers = var.session_key_user_role_arns
      }
    }
  }
}

resource "aws_kms_key" "session" {
  count = local.create_session_kms ? 1 : 0

  description             = "Encrypts Systems Manager session data, transcripts, and streamed session output."
  deletion_window_in_days = var.session_kms_key_deletion_window_days
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.session_kms[0].json

  tags = {
    Name = "${var.name_prefix}-ssm-sessions"
  }
}

resource "aws_kms_alias" "session" {
  count = local.create_session_kms ? 1 : 0

  name          = "alias/${var.name_prefix}-ssm-sessions"
  target_key_id = aws_kms_key.session[0].key_id
}

################################################################################
# Streamed session output
################################################################################

# Streaming puts session output in CloudWatch Logs as it happens, which is what makes a
# session watchable while it is still open rather than only after it closes.
resource "aws_cloudwatch_log_group" "session" {
  count = local.session_enabled ? 1 : 0

  name              = local.session_log_group_name
  retention_in_days = var.session_cloudwatch_retention_days
  kms_key_id        = local.session_kms_key_arn

  tags = {
    Name = local.session_log_group_name
  }
}

################################################################################
# Transcript bucket
################################################################################

resource "aws_s3_bucket" "session" {
  count = local.create_session_bucket ? 1 : 0

  bucket = local.session_bucket_name

  tags = {
    Name = local.session_bucket_name
  }
}

# ACLs disabled: a transcript written by a node is owned by this account, not by whichever
# principal the node happened to be using.
resource "aws_s3_bucket_ownership_controls" "session" {
  count = local.create_session_bucket ? 1 : 0

  bucket = aws_s3_bucket.session[0].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "session" {
  count = local.create_session_bucket ? 1 : 0

  bucket = aws_s3_bucket.session[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioning is what stops a transcript from being quietly replaced: the record of a
# session is an audit artefact, so an overwrite has to leave the original recoverable.
resource "aws_s3_bucket_versioning" "session" {
  count = local.create_session_bucket ? 1 : 0

  bucket = aws_s3_bucket.session[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "session" {
  count = local.create_session_bucket ? 1 : 0

  bucket = aws_s3_bucket.session[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = local.session_kms_key_arn != null ? "aws:kms" : "AES256"
      kms_master_key_id = local.session_kms_key_arn
    }

    bucket_key_enabled = local.session_kms_key_arn != null
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "session" {
  count = local.create_session_bucket ? 1 : 0

  bucket = aws_s3_bucket.session[0].id

  rule {
    id     = "expire-session-transcripts"
    status = "Enabled"

    filter {}

    expiration {
      days = var.session_log_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = var.session_log_noncurrent_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.session]
}

data "aws_iam_policy_document" "session_bucket" {
  count = local.create_session_bucket ? 1 : 0

  statement {
    sid       = "DenyNonTlsTraffic"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.session[0].arn, "${aws_s3_bucket.session[0].arn}/*"]

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

  # A transcript uploaded with an explicit encryption header that is not the expected one
  # is refused. The Null condition keeps the ordinary path working: an upload that sends
  # no header at all inherits the bucket's default encryption instead of being denied.
  dynamic "statement" {
    for_each = local.session_kms_key_arn != null ? [1] : []

    content {
      sid       = "DenyUnexpectedUploadEncryption"
      effect    = "Deny"
      actions   = ["s3:PutObject"]
      resources = ["${aws_s3_bucket.session[0].arn}/*"]

      principals {
        type        = "*"
        identifiers = ["*"]
      }

      condition {
        test     = "StringNotEquals"
        variable = "s3:x-amz-server-side-encryption"
        values   = ["aws:kms"]
      }

      condition {
        test     = "Null"
        variable = "s3:x-amz-server-side-encryption"
        values   = ["false"]
      }
    }
  }
}

resource "aws_s3_bucket_policy" "session" {
  count = local.create_session_bucket ? 1 : 0

  bucket = aws_s3_bucket.session[0].id
  policy = data.aws_iam_policy_document.session_bucket[0].json

  # Public access is blocked before a policy containing a wildcard-principal statement is
  # attached, so the bucket is never briefly governed by that statement alone.
  depends_on = [aws_s3_bucket_public_access_block.session]
}

################################################################################
# Session preferences
################################################################################

# The preferences document is what turns the settings above into behaviour. Systems
# Manager reads SSM-SessionManagerRunShell for every session in the region, so publishing
# it here is what makes logging non-optional for anyone who connects.
resource "aws_ssm_document" "session_preferences" {
  count = local.session_enabled ? 1 : 0

  name            = var.session_document_name
  document_type   = "Session"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "1.0"
    description   = "Session preferences for the managed-node fleet: encrypted transcripts, streamed output, and bounded session length."
    sessionType   = "Standard_Stream"
    inputs        = local.session_preferences
  })

  tags = {
    Name = var.session_document_name
  }

  lifecycle {
    precondition {
      condition     = !var.session_run_as_enabled || length(var.session_run_as_default_user) > 0
      error_message = "session_run_as_default_user must name an operating-system user when session_run_as_enabled is true."
    }

    precondition {
      condition     = var.session_kms_key_arn == null || !var.create_session_kms_key
      error_message = "Set either session_kms_key_arn to use an existing key or create_session_kms_key to create one, not both."
    }
  }
}

################################################################################
# Operator access
################################################################################

data "aws_iam_policy_document" "session_operator" {
  count = local.session_operator_policy_enabled ? 1 : 0

  # Access is granted by tag, never by instance ID, for the same reason patching is: the
  # fleet changes, the tag does not. A node that does not carry the tag key cannot be
  # connected to at all.
  statement {
    sid       = "AllowTaggedNodeSessions"
    effect    = "Allow"
    actions   = ["ssm:StartSession"]
    resources = ["arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*"]

    condition {
      test     = "StringLike"
      variable = "ssm:resourceTag/${var.session_access_tag_key}"
      values   = var.session_access_tag_values
    }

    # Requires the caller to hold explicit access to the session document being used,
    # which stops a session from silently running under preferences nobody reviewed.
    condition {
      test     = "BoolIfExists"
      variable = "ssm:SessionDocumentAccessCheck"
      values   = ["true"]
    }
  }

  statement {
    sid       = "AllowPreferencesDocument"
    effect    = "Allow"
    actions   = ["ssm:StartSession"]
    resources = ["arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:document/${var.session_document_name}"]
  }

  # An operator may end their own session and nobody else's. The session ID carries the
  # caller's identity, so the resource pattern is the whole control.
  statement {
    sid    = "AllowOwnSessionControl"
    effect = "Allow"

    actions = [
      "ssm:ResumeSession",
      "ssm:TerminateSession",
    ]

    resources = ["arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:session/$${aws:userid}-*"]
  }

  # Read-only calls the session client makes to find a node and report status.
  statement {
    sid    = "AllowSessionDiscovery"
    effect = "Allow"

    actions = [
      "ec2:DescribeInstances",
      "ssm:DescribeInstanceInformation",
      "ssm:DescribeSessions",
      "ssm:GetConnectionStatus",
    ]

    resources = ["*"]
  }

  # Traffic through a forwarded port never reaches the transcript, so tunnelling documents
  # are denied outright unless the caller has decided that trade-off is acceptable.
  dynamic "statement" {
    for_each = var.allow_session_port_forwarding ? [] : [1]

    content {
      sid       = "DenyPortForwarding"
      effect    = "Deny"
      actions   = ["ssm:StartSession"]
      resources = [for document in local.session_tunnel_documents : "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}::document/${document}"]
    }
  }

  # The transcript is evidence. An operator who can read it can review their own work;
  # nobody who holds only this policy can delete or overwrite what was recorded.
  dynamic "statement" {
    for_each = local.session_enabled && local.create_session_bucket ? [1] : []

    content {
      sid       = "AllowTranscriptRead"
      effect    = "Allow"
      actions   = ["s3:GetObject"]
      resources = ["${aws_s3_bucket.session[0].arn}/${local.session_log_prefix}/*"]
    }
  }

  dynamic "statement" {
    for_each = local.session_kms_key_arn != null ? [1] : []

    content {
      sid    = "AllowSessionKeyUse"
      effect = "Allow"

      actions = [
        "kms:Decrypt",
        "kms:DescribeKey",
        "kms:GenerateDataKey",
      ]

      resources = [local.session_kms_key_arn]
    }
  }
}

resource "aws_iam_policy" "session_operator" {
  count = local.session_operator_policy_enabled ? 1 : 0

  name        = "${var.name_prefix}-session-operator"
  description = "Scoped interactive access to managed nodes through Session Manager."
  policy      = data.aws_iam_policy_document.session_operator[0].json

  tags = {
    Name = "${var.name_prefix}-session-operator"
  }
}
