# Nightly EBS snapshots of the box's root volume (Data Lifecycle Manager).
#
# The root volume holds the identities (/var/lib/headlong/identities, bind
# mounted at app/.identities), and before 2026-09-26 nothing backed them up:
# a lost volume, a -replace rebuild without an export, or an rm -rf from a
# mind would have ended the persona for good. DLM snapshots the volume every
# night and keeps copies in a second region. Restore runbook: DEPLOY.md,
# "Restoring an identity from a snapshot".
#
# DLM runs under its own service role, so the instance role gains nothing:
# a mind that reaches the instance credentials still cannot list, read, or
# delete snapshots. The volume is unencrypted (built that way; encrypting
# means a rebuild), so local snapshots are too; the cross-region copies are
# encrypted with the target region's default EBS key.
#
# A live snapshot is crash consistent. That is enough here: ext4 journals,
# and the trajectory is append-only, so the worst case is a torn last line.

variable "backup_copy_region" {
  description = "Second region that receives encrypted copies of the snapshots. Must be enabled on the account (ap-southeast-4 is opt-in and is not)."
  type        = string
  default     = "ap-southeast-1"
}

# The policy targets volumes by this tag. The value names the stack so each
# stack's policy snapshots only its own box.
resource "aws_ec2_tag" "backup" {
  resource_id = aws_instance.shellm.root_block_device[0].volume_id
  key         = "headlong-backup"
  value       = "shellm-${var.subdomain}"
}

resource "aws_iam_role" "dlm" {
  name = "shellm-${var.subdomain}-dlm"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "dlm.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "backup" {
  # DLM allows only letters, digits, spaces, _ and - here.
  description        = "shellm-${var.subdomain} root volume daily 14 weekly 8 copies in ${var.backup_copy_region}"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]
    target_tags = {
      "headlong-backup" = "shellm-${var.subdomain}"
    }

    # 13:00 UTC is 06:00 Pacific. DLM starts within the hour after.
    schedule {
      name      = "daily"
      copy_tags = true
      tags_to_add = {
        "headlong-backup-schedule" = "daily"
      }

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["13:00"]
      }

      retain_rule {
        count = 14
      }

      cross_region_copy_rule {
        target    = var.backup_copy_region
        encrypted = true
        copy_tags = true
        retain_rule {
          interval      = 7
          interval_unit = "DAYS"
        }
      }
    }

    # Sundays. When both schedules fire the same day DLM takes one snapshot
    # and keeps it for the longer retention.
    schedule {
      name      = "weekly"
      copy_tags = true
      tags_to_add = {
        "headlong-backup-schedule" = "weekly"
      }

      create_rule {
        cron_expression = "cron(0 13 ? * SUN *)"
      }

      retain_rule {
        count = 8
      }

      cross_region_copy_rule {
        target    = var.backup_copy_region
        encrypted = true
        copy_tags = true
        retain_rule {
          interval      = 8
          interval_unit = "WEEKS"
        }
      }
    }
  }

  tags = {
    Name = "shellm-${var.subdomain}-backup"
  }
}
