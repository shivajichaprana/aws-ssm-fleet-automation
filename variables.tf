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
