# Fleet management is regional: Systems Manager patch baselines, maintenance
# windows, and associations all live in the region that owns the managed nodes.
# Deploy one instance of this configuration per region that hosts a fleet.
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.default_tags
  }
}
