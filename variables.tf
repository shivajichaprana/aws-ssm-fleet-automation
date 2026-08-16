variable "aws_region" {
  description = "Region that hosts the managed-node fleet."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.aws_region))
    error_message = "aws_region must be a valid region identifier, for example us-east-1."
  }
}

variable "name_prefix" {
  description = "Prefix applied to every Systems Manager resource this configuration creates."
  type        = string
  default     = "fleet"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,24}$", var.name_prefix))
    error_message = "name_prefix must be 2-25 characters, lowercase alphanumeric or hyphen, and start with a letter."
  }
}

variable "default_tags" {
  description = "Tags applied to every resource that supports tagging."
  type        = map(string)
  default = {
    ManagedBy = "terraform"
    Component = "fleet-automation"
  }
}

variable "patch_group_tag_key" {
  description = <<-EOT
    Instance tag key used to bind a managed node to a patch baseline. Systems Manager
    only recognises the literal key "Patch Group" for baseline association, so this is
    exposed for readability rather than as a general-purpose override.
  EOT
  type        = string
  default     = "Patch Group"

  validation {
    condition     = var.patch_group_tag_key == "Patch Group"
    error_message = "Systems Manager only associates baselines through the tag key \"Patch Group\"."
  }
}

variable "patch_baselines" {
  description = <<-EOT
    Patch baselines to create, keyed by a short logical name. Each baseline declares the
    operating system it applies to, the approval rules that decide which patches are
    auto-approved, and the patch groups (instance tag values) it governs.

    A patch group may only be attached to ONE baseline per operating system; the
    configuration validates that constraint before anything is created.
  EOT

  type = map(object({
    operating_system = string
    description      = optional(string)
    set_as_default   = optional(bool, false)
    approved_patches = optional(list(string), [])
    rejected_patches = optional(list(string), [])
    # BLOCK refuses the patch and its dependencies; ALLOW_AS_DEPENDENCY installs it only
    # when another approved patch requires it.
    rejected_patches_action = optional(string, "BLOCK")
    patch_groups            = optional(list(string), [])

    approval_rules = list(object({
      # Exactly one of approve_after_days / approve_until_date must be set.
      approve_after_days  = optional(number)
      approve_until_date  = optional(string)
      compliance_level    = optional(string, "HIGH")
      enable_non_security = optional(bool, false)
      # Filter keys are operating-system specific, for example CLASSIFICATION,
      # SEVERITY, PRODUCT, MSRC_SEVERITY, PRIORITY, SECTION.
      patch_filters = map(list(string))
    }))
  }))

  default = {
    amazon-linux = {
      operating_system = "AMAZON_LINUX_2"
      description      = "Security and critical bug fixes for Amazon Linux 2 nodes."
      set_as_default   = true
      patch_groups     = ["linux-production", "linux-non-production"]

      approval_rules = [
        {
          approve_after_days = 7
          compliance_level   = "CRITICAL"
          patch_filters = {
            CLASSIFICATION = ["Security"]
            SEVERITY       = ["Critical", "Important"]
          }
        },
        {
          approve_after_days = 21
          compliance_level   = "MEDIUM"
          patch_filters = {
            CLASSIFICATION = ["Bugfix"]
          }
        },
      ]
    }

    windows = {
      operating_system = "WINDOWS"
      description      = "Security updates and critical updates for Windows nodes."
      set_as_default   = true
      patch_groups     = ["windows-production", "windows-non-production"]

      approval_rules = [
        {
          approve_after_days = 7
          compliance_level   = "CRITICAL"
          patch_filters = {
            CLASSIFICATION = ["SecurityUpdates", "CriticalUpdates"]
            MSRC_SEVERITY  = ["Critical", "Important"]
          }
        },
      ]
    }
  }

  validation {
    condition = alltrue([
      for b in var.patch_baselines : contains([
        "AMAZON_LINUX", "AMAZON_LINUX_2", "AMAZON_LINUX_2022", "AMAZON_LINUX_2023",
        "CENTOS", "DEBIAN", "MACOS", "ORACLE_LINUX", "RASPBIAN", "REDHAT_ENTERPRISE_LINUX",
        "ROCKY_LINUX", "SUSE", "UBUNTU", "WINDOWS",
      ], b.operating_system)
    ])
    error_message = "Each baseline operating_system must be a Systems Manager supported platform identifier."
  }

  validation {
    condition = alltrue([
      for b in var.patch_baselines : contains(["BLOCK", "ALLOW_AS_DEPENDENCY"], b.rejected_patches_action)
    ])
    error_message = "rejected_patches_action must be BLOCK or ALLOW_AS_DEPENDENCY."
  }

  validation {
    condition     = alltrue([for b in var.patch_baselines : length(b.approval_rules) > 0])
    error_message = "Each baseline must declare at least one approval rule."
  }

  validation {
    condition = alltrue(flatten([
      for b in var.patch_baselines : [
        for r in b.approval_rules :
        (r.approve_after_days == null) != (r.approve_until_date == null)
      ]
    ]))
    error_message = "Each approval rule must set exactly one of approve_after_days or approve_until_date."
  }

  validation {
    condition = alltrue(flatten([
      for b in var.patch_baselines : [
        for r in b.approval_rules :
        r.approve_after_days == null || try(r.approve_after_days >= 0 && r.approve_after_days <= 360, false)
      ]
    ]))
    error_message = "approve_after_days must be between 0 and 360."
  }

  validation {
    condition = alltrue(flatten([
      for b in var.patch_baselines : [
        for r in b.approval_rules :
        r.approve_until_date == null || can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", r.approve_until_date))
      ]
    ]))
    error_message = "approve_until_date must be formatted as YYYY-MM-DD."
  }

  validation {
    condition = alltrue(flatten([
      for b in var.patch_baselines : [
        for r in b.approval_rules :
        contains(["CRITICAL", "HIGH", "MEDIUM", "LOW", "INFORMATIONAL", "UNSPECIFIED"], r.compliance_level)
      ]
    ]))
    error_message = "compliance_level must be one of CRITICAL, HIGH, MEDIUM, LOW, INFORMATIONAL, UNSPECIFIED."
  }

  validation {
    condition = alltrue(flatten([
      for b in var.patch_baselines : [
        for r in b.approval_rules : [
          for k, v in r.patch_filters :
          contains([
            "ARCH", "ADVISORY_ID", "BUGZILLA_ID", "CLASSIFICATION", "CVE_ID", "EPOCH",
            "MSRC_SEVERITY", "NAME", "PATCH_ID", "PATCH_SET", "PRIORITY", "PRODUCT",
            "PRODUCT_FAMILY", "RELEASE", "REPOSITORY", "SECTION", "SECURITY", "SEVERITY", "VERSION",
          ], k) && length(v) > 0
        ]
      ]
    ]))
    error_message = "Every patch filter key must be a supported Systems Manager filter and carry at least one value."
  }

  validation {
    condition = alltrue(flatten([
      for b in var.patch_baselines : [
        for g in b.patch_groups : can(regex("^[a-zA-Z0-9._:/=+@-]{1,256}$", g))
      ]
    ]))
    error_message = "Patch group values must be valid tag values (1-256 characters)."
  }
}

variable "maintenance_windows" {
  description = <<-EOT
    Maintenance windows that run the patch operation against a patch group. Each window
    targets exactly one patch group so that the blast radius of a single window is a
    single, explicitly named slice of the fleet.

    Set operation to "Scan" for a reporting-only window and "Install" for one that
    actually applies approved patches.
  EOT

  type = map(object({
    patch_group        = string
    schedule           = string
    schedule_timezone  = optional(string, "UTC")
    duration           = number
    cutoff             = number
    operation          = optional(string, "Install")
    reboot_option      = optional(string, "RebootIfNeeded")
    max_concurrency    = optional(string, "10%")
    max_errors         = optional(string, "5%")
    priority           = optional(number, 1)
    enabled            = optional(bool, true)
    description        = optional(string)
    resource_tag_scope = optional(map(string), {})
  }))

  default = {
    linux-non-production = {
      patch_group     = "linux-non-production"
      schedule        = "cron(0 2 ? * SUN *)"
      duration        = 4
      cutoff          = 1
      operation       = "Install"
      max_concurrency = "25%"
      description     = "Weekly patch install for non-production Linux nodes."
    }

    linux-production = {
      patch_group     = "linux-production"
      schedule        = "cron(0 3 ? * SAT *)"
      duration        = 4
      cutoff          = 1
      operation       = "Install"
      max_concurrency = "10%"
      max_errors      = "2%"
      priority        = 1
      description     = "Weekly patch install for production Linux nodes, tightly rate limited."
    }

    windows-production = {
      patch_group     = "windows-production"
      schedule        = "cron(0 4 ? * SAT *)"
      duration        = 4
      cutoff          = 1
      operation       = "Install"
      max_concurrency = "10%"
      max_errors      = "2%"
      description     = "Weekly patch install for production Windows nodes."
    }
  }

  validation {
    condition = alltrue([
      for w in var.maintenance_windows :
      can(regex("^(cron|rate)\\(.+\\)$", w.schedule))
    ])
    error_message = "schedule must be a cron(...) or rate(...) expression."
  }

  validation {
    condition = alltrue([
      for w in var.maintenance_windows :
      w.duration >= 1 && w.duration <= 24
    ])
    error_message = "duration must be between 1 and 24 hours."
  }

  validation {
    condition = alltrue([
      for w in var.maintenance_windows :
      w.cutoff >= 0 && w.cutoff < w.duration
    ])
    error_message = "cutoff must be zero or greater and strictly smaller than duration."
  }

  validation {
    condition = alltrue([
      for w in var.maintenance_windows : contains(["Scan", "Install"], w.operation)
    ])
    error_message = "operation must be Scan or Install."
  }

  validation {
    condition = alltrue([
      for w in var.maintenance_windows :
      contains(["RebootIfNeeded", "NoReboot"], w.reboot_option)
    ])
    error_message = "reboot_option must be RebootIfNeeded or NoReboot."
  }

  validation {
    condition = alltrue([
      for w in var.maintenance_windows :
      can(regex("^([0-9]+|[0-9]{1,2}%|100%)$", w.max_concurrency)) &&
      can(regex("^([0-9]+|[0-9]{1,2}%|100%)$", w.max_errors))
    ])
    error_message = "max_concurrency and max_errors must be an absolute count or a percentage such as 10%."
  }

  validation {
    condition = alltrue([
      for w in var.maintenance_windows : w.priority >= 0 && w.priority <= 10
    ])
    error_message = "priority must be between 0 and 10."
  }
}

variable "patch_log_retention_days" {
  description = "Retention for the CloudWatch log group that captures patch command output."
  type        = number
  default     = 90

  validation {
    condition = contains([
      1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653,
    ], var.patch_log_retention_days)
    error_message = "patch_log_retention_days must be a retention period CloudWatch Logs accepts."
  }
}

variable "patch_log_kms_key_arn" {
  description = "Optional customer managed key ARN used to encrypt the patch log group. Leave null to use the service default key."
  type        = string
  default     = null

  validation {
    condition     = var.patch_log_kms_key_arn == null || can(regex("^arn:aws[a-z-]*:kms:", var.patch_log_kms_key_arn))
    error_message = "patch_log_kms_key_arn must be a KMS key ARN or null."
  }
}

variable "maintenance_window_role_arn" {
  description = "Optional pre-existing service role ARN for maintenance window tasks. Leave null to let this configuration create one."
  type        = string
  default     = null

  validation {
    condition     = var.maintenance_window_role_arn == null || can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/", var.maintenance_window_role_arn))
    error_message = "maintenance_window_role_arn must be an IAM role ARN or null."
  }
}

variable "state_manager_associations" {
  description = <<-EOT
    State Manager associations that hold the fleet at its declared state. Each association
    binds one document to a tag-selected slice of the fleet on a schedule.

    Exactly one of document_name or local_document must be set. Use document_name for an
    AWS-managed or externally owned document, and local_document for one of the documents
    shipped in this repository (the map key of the file in documents/, without its
    extension).

    An association with enabled = false is described here but not created, which is how a
    document that changes host configuration ships ready to adopt rather than switched on.
  EOT

  type = map(object({
    document_name    = optional(string)
    local_document   = optional(string)
    association_name = optional(string)
    document_version = optional(string)
    description      = optional(string)

    schedule_expression = optional(string)
    schedule_offset     = optional(number)
    # When true the association runs only on its schedule, never immediately after it is
    # created or changed. Preferred for anything that touches production nodes.
    apply_only_at_cron_interval = optional(bool, false)

    compliance_severity = optional(string, "MEDIUM")
    sync_compliance     = optional(string, "AUTO")
    max_concurrency     = optional(string, "10%")
    max_errors          = optional(string, "5%")

    parameters = optional(map(string), {})
    enabled    = optional(bool, true)

    targets = list(object({
      key    = string
      values = list(string)
    }))
  }))

  default = {
    agent-update = {
      document_name       = "AWS-UpdateSSMAgent"
      description         = "Keeps the SSM Agent current so every other capability keeps working."
      schedule_expression = "rate(14 days)"
      compliance_severity = "HIGH"
      max_concurrency     = "10%"
      max_errors          = "5%"

      targets = [
        {
          key    = "InstanceIds"
          values = ["*"]
        },
      ]
    }

    patch-scan = {
      document_name       = "AWS-RunPatchBaseline"
      description         = "Reports patch compliance between install windows without changing the node."
      schedule_expression = "rate(1 day)"
      compliance_severity = "CRITICAL"
      max_concurrency     = "20%"
      max_errors          = "10%"

      parameters = {
        Operation    = "Scan"
        RebootOption = "NoReboot"
      }

      targets = [
        {
          key    = "InstanceIds"
          values = ["*"]
        },
      ]
    }

    service-convergence = {
      local_document              = "service-convergence"
      description                 = "Holds the agent services at enabled and running."
      schedule_expression         = "rate(1 hour)"
      compliance_severity         = "HIGH"
      apply_only_at_cron_interval = false
      max_concurrency             = "20%"
      max_errors                  = "10%"

      targets = [
        {
          key    = "InstanceIds"
          values = ["*"]
        },
      ]
    }

    fleet-diagnostics = {
      local_document      = "fleet-diagnostics"
      description         = "Reports host health so a degraded node surfaces as non-compliant."
      schedule_expression = "rate(12 hours)"
      compliance_severity = "MEDIUM"
      max_concurrency     = "20%"
      max_errors          = "20%"

      parameters = {
        utilisationWarnPercent = "85"
      }

      targets = [
        {
          key    = "InstanceIds"
          values = ["*"]
        },
      ]
    }

    # Ships described but switched off: host hardening rewrites sshd configuration, so it
    # is adopted deliberately after the values below have been reviewed for the fleet.
    host-hardening = {
      local_document              = "host-hardening"
      description                 = "Converges hosts onto the ssh and SMB hardening baseline."
      schedule_expression         = "cron(0 5 ? * SUN *)"
      compliance_severity         = "HIGH"
      apply_only_at_cron_interval = true
      max_concurrency             = "5%"
      max_errors                  = "1"
      enabled                     = false

      targets = [
        {
          key    = "tag:Patch Group"
          values = ["linux-non-production"]
        },
      ]
    }
  }

  validation {
    condition = alltrue([
      for a in var.state_manager_associations :
      (a.document_name == null) != (a.local_document == null)
    ])
    error_message = "Each association must set exactly one of document_name or local_document."
  }

  validation {
    condition = alltrue([
      for a in var.state_manager_associations :
      a.schedule_expression == null || can(regex("^(cron|rate)\\(.+\\)$", a.schedule_expression))
    ])
    error_message = "schedule_expression must be a cron(...) or rate(...) expression."
  }

  validation {
    condition = alltrue([
      for a in var.state_manager_associations :
      contains(["CRITICAL", "HIGH", "MEDIUM", "LOW", "INFORMATIONAL", "UNSPECIFIED"], a.compliance_severity)
    ])
    error_message = "compliance_severity must be one of CRITICAL, HIGH, MEDIUM, LOW, INFORMATIONAL, UNSPECIFIED."
  }

  validation {
    condition = alltrue([
      for a in var.state_manager_associations : contains(["AUTO", "MANUAL"], a.sync_compliance)
    ])
    error_message = "sync_compliance must be AUTO or MANUAL."
  }

  validation {
    condition = alltrue([
      for a in var.state_manager_associations :
      can(regex("^([0-9]+|[0-9]{1,2}%|100%)$", a.max_concurrency)) &&
      can(regex("^([0-9]+|[0-9]{1,2}%|100%)$", a.max_errors))
    ])
    error_message = "max_concurrency and max_errors must be an absolute count or a percentage such as 10%."
  }

  validation {
    condition = alltrue([
      for a in var.state_manager_associations : length(a.targets) > 0
    ])
    error_message = "Each association must declare at least one target."
  }

  validation {
    condition = alltrue(flatten([
      for a in var.state_manager_associations : [
        for t in a.targets :
        length(t.key) > 0 && length(t.values) > 0 && length(t.values) <= 50
      ]
    ]))
    error_message = "Each association target must carry a key and between 1 and 50 values."
  }

  validation {
    condition = alltrue([
      for a in var.state_manager_associations :
      a.schedule_offset == null || try(a.schedule_offset >= 1 && a.schedule_offset <= 6, false)
    ])
    error_message = "schedule_offset must be between 1 and 6 days when set."
  }
}

variable "document_target_type" {
  description = <<-EOT
    Resource type the published Command documents may target. The default "/" permits any
    managed node, which covers EC2 instances and hybrid activations alike; narrow it to
    "/AWS::EC2::Instance" for an EC2-only fleet.
  EOT
  type        = string
  default     = "/"

  validation {
    condition     = can(regex("^(/|/AWS::[A-Za-z0-9:]+)$", var.document_target_type))
    error_message = "document_target_type must be \"/\" or a resource type such as /AWS::EC2::Instance."
  }
}

variable "association_output_s3_bucket" {
  description = <<-EOT
    Optional existing S3 bucket that receives full association command output. Systems
    Manager truncates output it returns inline, so a bucket is the way to keep the whole
    log of a run. Leave null to keep output inline only.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.association_output_s3_bucket == null || can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.association_output_s3_bucket))
    error_message = "association_output_s3_bucket must be a valid S3 bucket name or null."
  }
}

variable "association_output_s3_key_prefix" {
  description = "Key prefix applied to association output written to S3."
  type        = string
  default     = "state-manager"

  validation {
    condition     = can(regex("^[A-Za-z0-9!_.*'()/-]{0,256}$", var.association_output_s3_key_prefix))
    error_message = "association_output_s3_key_prefix must be a valid S3 key prefix."
  }
}

################################################################################
# Inventory
################################################################################

variable "enable_inventory" {
  description = <<-EOT
    Whether to schedule inventory collection across the fleet. Systems Manager permits
    exactly one inventory association per managed node, so leave this off if inventory is
    already scheduled for these nodes by another configuration.
  EOT
  type        = bool
  default     = true
}

variable "inventory_schedule_expression" {
  description = "How often managed nodes report inventory. Daily collection is enough for software and configuration drift."
  type        = string
  default     = "rate(1 day)"

  validation {
    condition     = can(regex("^(cron|rate)\\(.+\\)$", var.inventory_schedule_expression))
    error_message = "inventory_schedule_expression must be a cron(...) or rate(...) expression."
  }
}

variable "inventory_compliance_severity" {
  description = "Severity recorded when a node fails to report inventory."
  type        = string
  default     = "MEDIUM"

  validation {
    condition = contains(
      ["CRITICAL", "HIGH", "MEDIUM", "LOW", "INFORMATIONAL", "UNSPECIFIED"],
      var.inventory_compliance_severity,
    )
    error_message = "inventory_compliance_severity must be one of CRITICAL, HIGH, MEDIUM, LOW, INFORMATIONAL, UNSPECIFIED."
  }
}

variable "inventory_targets" {
  description = <<-EOT
    Nodes that report inventory. The default covers every managed node in the region,
    which is normally what you want: inventory is read-only metadata collection, and a
    node missing from inventory is a node you cannot reason about.
  EOT

  type = list(object({
    key    = string
    values = list(string)
  }))

  default = [
    {
      key    = "InstanceIds"
      values = ["*"]
    },
  ]

  validation {
    condition     = length(var.inventory_targets) > 0
    error_message = "inventory_targets must declare at least one target."
  }

  validation {
    condition = alltrue([
      for t in var.inventory_targets :
      length(t.key) > 0 && length(t.values) > 0 && length(t.values) <= 50
    ])
    error_message = "Each inventory target must carry a key and between 1 and 50 values."
  }
}

variable "inventory_collection" {
  description = <<-EOT
    Categories of inventory each node collects. The defaults gather the metadata that
    answers most fleet questions — what is installed, what is running, and how the host is
    connected — without the volume that file and registry collection adds.

    files and windows_registry are JSON documents describing the paths or keys to collect,
    not flags. Leave them null to collect neither.
  EOT

  type = object({
    applications                  = optional(bool, true)
    aws_components                = optional(bool, true)
    billing_info                  = optional(bool, false)
    custom_inventory              = optional(bool, true)
    instance_detailed_information = optional(bool, true)
    network_config                = optional(bool, true)
    services                      = optional(bool, true)
    windows_roles                 = optional(bool, true)
    windows_updates               = optional(bool, true)
    files                         = optional(string)
    windows_registry              = optional(string)
  })

  default = {}

  validation {
    condition     = var.inventory_collection.files == null || can(jsondecode(var.inventory_collection.files))
    error_message = "inventory_collection.files must be a JSON document describing the paths to collect."
  }

  validation {
    condition     = var.inventory_collection.windows_registry == null || can(jsondecode(var.inventory_collection.windows_registry))
    error_message = "inventory_collection.windows_registry must be a JSON document describing the keys to collect."
  }
}

variable "enable_resource_data_sync" {
  description = <<-EOT
    Whether to sync inventory and compliance data to S3. Systems Manager only retains this
    data for a limited window, so the sync is what turns fleet state into history that can
    be queried with ordinary data tools.
  EOT
  type        = bool
  default     = true
}

variable "inventory_sync_bucket_name" {
  description = "Optional existing bucket that receives synced inventory data. Leave null to have this configuration create and harden one."
  type        = string
  default     = null

  validation {
    condition     = var.inventory_sync_bucket_name == null || can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.inventory_sync_bucket_name))
    error_message = "inventory_sync_bucket_name must be a valid S3 bucket name or null."
  }
}

variable "inventory_sync_key_prefix" {
  description = "Key prefix under which synced inventory data is written."
  type        = string
  default     = "ssm-inventory"

  validation {
    condition     = can(regex("^[A-Za-z0-9!_.*'()/-]{1,256}$", var.inventory_sync_key_prefix))
    error_message = "inventory_sync_key_prefix must be a valid, non-empty S3 key prefix."
  }
}

variable "create_inventory_sync_kms_key" {
  description = "Whether to create a customer managed key for the sync destination. Only applies when this configuration creates the bucket."
  type        = bool
  default     = true
}

variable "inventory_sync_kms_key_arn" {
  description = "Optional existing key ARN used to encrypt synced inventory data. Takes precedence over a key created here."
  type        = string
  default     = null

  validation {
    condition     = var.inventory_sync_kms_key_arn == null || can(regex("^arn:aws[a-z-]*:kms:", var.inventory_sync_kms_key_arn))
    error_message = "inventory_sync_kms_key_arn must be a KMS key ARN or null."
  }
}

variable "inventory_kms_key_deletion_window_days" {
  description = "Waiting period before a scheduled deletion of the inventory key completes."
  type        = number
  default     = 30

  validation {
    condition     = var.inventory_kms_key_deletion_window_days >= 7 && var.inventory_kms_key_deletion_window_days <= 30
    error_message = "inventory_kms_key_deletion_window_days must be between 7 and 30."
  }
}

variable "inventory_retention_days" {
  description = "How long synced inventory objects are kept before expiry."
  type        = number
  default     = 365

  validation {
    condition     = var.inventory_retention_days >= 1 && var.inventory_retention_days <= 3653
    error_message = "inventory_retention_days must be between 1 and 3653."
  }
}

variable "inventory_noncurrent_retention_days" {
  description = "How long superseded object versions are kept in the sync bucket."
  type        = number
  default     = 30

  validation {
    condition     = var.inventory_noncurrent_retention_days >= 1 && var.inventory_noncurrent_retention_days <= 3653
    error_message = "inventory_noncurrent_retention_days must be between 1 and 3653."
  }
}

################################################################################
# Compliance reporting
################################################################################

variable "enable_compliance_reporting" {
  description = "Whether to create the read-only compliance reporter, its notification topic, and its schedule."
  type        = bool
  default     = true
}

variable "compliance_report_schedule_expression" {
  description = "How often the fleet compliance digest is produced."
  type        = string
  default     = "cron(0 6 ? * MON *)"

  validation {
    condition     = can(regex("^(cron|rate)\\(.+\\)$", var.compliance_report_schedule_expression))
    error_message = "compliance_report_schedule_expression must be a cron(...) or rate(...) expression."
  }
}

variable "compliance_report_severities" {
  description = <<-EOT
    Overall severities a non-compliant resource must carry to appear in the report. The
    default keeps the digest to what an operator would act on; the underlying data for
    every severity is still in the resource data sync.
  EOT
  type        = list(string)
  default     = ["CRITICAL", "HIGH"]

  validation {
    condition     = length(var.compliance_report_severities) > 0
    error_message = "compliance_report_severities must list at least one severity."
  }

  validation {
    condition = alltrue([
      for s in var.compliance_report_severities :
      contains(["CRITICAL", "HIGH", "MEDIUM", "LOW", "INFORMATIONAL", "UNSPECIFIED"], s)
    ])
    error_message = "Each entry in compliance_report_severities must be a Systems Manager severity."
  }
}

variable "compliance_report_s3_bucket" {
  description = <<-EOT
    Optional bucket that receives compliance report objects. Leave null to write reports
    alongside inventory in the bucket this configuration creates. Set it when the sync
    bucket was supplied externally and is not writable by this account's report function.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.compliance_report_s3_bucket == null || can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.compliance_report_s3_bucket))
    error_message = "compliance_report_s3_bucket must be a valid S3 bucket name or null."
  }
}

variable "compliance_report_kms_key_arn" {
  description = "Key used to encrypt report objects when they are written to a caller-supplied bucket."
  type        = string
  default     = null

  validation {
    condition     = var.compliance_report_kms_key_arn == null || can(regex("^arn:aws[a-z-]*:kms:", var.compliance_report_kms_key_arn))
    error_message = "compliance_report_kms_key_arn must be a KMS key ARN or null."
  }
}

variable "compliance_report_key_prefix" {
  description = "Key prefix under which compliance report objects are written."
  type        = string
  default     = "compliance-reports"

  validation {
    condition     = can(regex("^[A-Za-z0-9!_.*'()/-]{1,256}$", var.compliance_report_key_prefix))
    error_message = "compliance_report_key_prefix must be a valid, non-empty S3 key prefix."
  }
}

variable "compliance_notification_emails" {
  description = "Addresses subscribed to the compliance digest. Each subscription must be confirmed from the address itself."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for e in var.compliance_notification_emails :
      can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[a-zA-Z]{2,}$", e))
    ])
    error_message = "Each entry in compliance_notification_emails must be an email address."
  }
}

variable "compliance_max_resources_in_summary" {
  description = "Resources listed in the published digest. The full set always stays in the report object."
  type        = number
  default     = 25

  validation {
    condition     = var.compliance_max_resources_in_summary >= 1 && var.compliance_max_resources_in_summary <= 200
    error_message = "compliance_max_resources_in_summary must be between 1 and 200."
  }
}

variable "compliance_report_timeout_seconds" {
  description = "Timeout for the compliance reporter. A large fleet pages through many compliance summaries."
  type        = number
  default     = 300

  validation {
    condition     = var.compliance_report_timeout_seconds >= 30 && var.compliance_report_timeout_seconds <= 900
    error_message = "compliance_report_timeout_seconds must be between 30 and 900."
  }
}

variable "compliance_report_memory_mb" {
  description = "Memory allocated to the compliance reporter."
  type        = number
  default     = 512

  validation {
    condition     = var.compliance_report_memory_mb >= 128 && var.compliance_report_memory_mb <= 3008
    error_message = "compliance_report_memory_mb must be between 128 and 3008."
  }
}

variable "compliance_log_retention_days" {
  description = "Retention for the compliance reporter log group."
  type        = number
  default     = 90

  validation {
    condition = contains([
      1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653,
    ], var.compliance_log_retention_days)
    error_message = "compliance_log_retention_days must be a retention period CloudWatch Logs accepts."
  }
}

variable "compliance_log_kms_key_arn" {
  description = "Optional customer managed key ARN used to encrypt the compliance reporter log group."
  type        = string
  default     = null

  validation {
    condition     = var.compliance_log_kms_key_arn == null || can(regex("^arn:aws[a-z-]*:kms:", var.compliance_log_kms_key_arn))
    error_message = "compliance_log_kms_key_arn must be a KMS key ARN or null."
  }
}

variable "compliance_log_level" {
  description = "Python log level for the compliance reporter."
  type        = string
  default     = "INFO"

  validation {
    condition     = contains(["DEBUG", "INFO", "WARNING", "ERROR"], var.compliance_log_level)
    error_message = "compliance_log_level must be DEBUG, INFO, WARNING, or ERROR."
  }
}
