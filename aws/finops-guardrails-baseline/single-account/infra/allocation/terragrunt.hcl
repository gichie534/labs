# The allocation layer: what makes a cost number attributable to something.
#
# Budgets and anomaly detection can only ever say "this ACCOUNT spent too much". This unit is what turns
# that into "this thing spent too much", and it is here rather than in a later lab because both halves
# are effectively one-way: cost data already recorded does not gain tag columns retroactively, and a cost
# category applies only from its effective month onward. Added late, the price is not effort — it is a
# permanent hole in the history you most want to explain.
#
# The cost category maps this account's spend into three buckets that are genuinely useful to an
# individual practitioner:
#
#   iac-managed    — anything provisioned by Terragrunt in these repos (every lab's root.hcl stamps
#                    ManagedBy = terragrunt via default_tags).
#   shared-charges — tax and support, which are account-wide and can never carry a resource tag. Matched
#                    on the RECORD_TYPE dimension precisely because no tag rule could ever catch them.
#   untagged       — the default, i.e. everything else. On a practice account that is mostly things
#                    clicked together in the console and forgotten. Naming the gap is the point: an
#                    unnamed gap is invisible, a named one is a number you can watch shrink.
#
# Tag ACTIVATION is separate and opt-in via FINOPS_COST_ALLOCATION_TAG_KEYS, because AWS only accepts tag
# keys it has already discovered on a real resource (up to 24h after first use). Activating too early
# fails the apply — so: run the lab, wait a day, then set the variable and re-apply.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/cost-allocation?ref=aws-cost-allocation-v0.1.0"
}

locals {
  raw_tag_keys = get_env("FINOPS_COST_ALLOCATION_TAG_KEYS", "")
  tag_keys = [
    for key in split(",", local.raw_tag_keys) : trimspace(key) if trimspace(key) != ""
  ]
}

inputs = {
  active_cost_allocation_tag_keys = local.tag_keys

  cost_categories = {
    "finops-baseline-attribution" = {
      # Everything no rule matches. On a practice account this bucket is the interesting one.
      default_value = "untagged"

      # Evaluated in order; first match wins.
      rules = [
        {
          value      = "iac-managed"
          tag_key    = "ManagedBy"
          tag_values = ["terragrunt"]
        },
        {
          value            = "shared-charges"
          dimension_key    = "RECORD_TYPE"
          dimension_values = ["Tax", "Support"]
        },
      ]
    }
  }

  tags = {
    Environment = "lab"
  }
}
