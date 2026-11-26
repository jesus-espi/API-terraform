terraform {
  required_version = ">= 1.5.0"
}

variable "server_url" {
  type = string
}

variable "sa_token" {
  type      = string
  sensitive = true
}

# ---------------------------------------------------------------------------
# Exercise 2.8 - API2-JesusEspi managed as code
# The pipeline applies the desired deployment state below to the existing
# API2-JesusEspi (sharding tag from 2.7 + tenant routing on the endpoints)
# and redeploys it. Everything else on the API (flows, cache, failover...)
# is kept as it is.
# ---------------------------------------------------------------------------
locals {
  org_id = "38907341-741d-42af-9073-41741de2af61"
  env_id = "b8135005-7573-4ed5-9350-0575739ed56a" # Development
  api_id = "33f103aa-33e3-40a6-b103-aa33e3e0a6f1" # API2-JesusEspi

  desired = {
    # Sharding tag from exercise 2.7: only gateways tagged "private"
    tags = ["private"]

    # Tenant routing rules per endpoint (tenant keys defined in the org)
    endpoint_tenants = {
      "primary-petstore-v2" = ["eu"]
      "secondary-httpbin"   = []
    }

    deployment_label = "Terraform CI/CD - tags + tenants"
  }
}

resource "terraform_data" "api2_jesusespi" {
  triggers_replace = [
    sha256(jsonencode(local.desired))
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      BASE_URL="${var.server_url}/v2/environments/${local.env_id}"
      AUTH="Authorization: Bearer ${var.sa_token}"
      API_ID="${local.api_id}"

      echo "1. Reading current definition of API2-JesusEspi..."
      CURRENT=$(curl -sS -f "$BASE_URL/apis/$API_ID" -H "$AUTH")
      echo "$CURRENT" | jq '{name, tags, deploymentState, endpoints: [.endpointGroups[].endpoints[] | {name, tenants}]}'

      echo "2. Applying desired state (sharding tag + tenants)..."
      BODY=$(echo "$CURRENT" | jq --argjson d '${jsonencode(local.desired)}' '
        {name, apiVersion, definitionVersion, type, description, tags, labels, categories,
         listeners, endpointGroups, analytics, properties, resources, flowExecution, flows,
         responseTemplates, lifecycleState, visibility, groups, failover, services,
         disableMembershipNotifications, allowedInApiProducts, allowMultiJwtOauth2Subscriptions}
        | with_entries(select(.value != null))
        | .tags = $d.tags
        | .endpointGroups |= map(.endpoints |= map(
            if $d.endpoint_tenants[.name] != null then .tenants = $d.endpoint_tenants[.name] else . end))')

      curl -sS -f -X PUT "$BASE_URL/apis/$API_ID" -H "$AUTH" \
        -H "Content-Type: application/json" -d "$BODY" > /dev/null

      echo "3. Deploying API2-JesusEspi to the tagged gateways..."
      curl -sS -f -X POST "$BASE_URL/apis/$API_ID/deployments" -H "$AUTH" \
        -H "Content-Type: application/json" \
        -d '{"deploymentLabel":"${local.desired.deployment_label}"}' > /dev/null

      echo "4. Verifying deployed state..."
      curl -sS -f "$BASE_URL/apis/$API_ID" -H "$AUTH" \
        | jq '{name, state, deploymentState, tags, endpoints: [.endpointGroups[].endpoints[] | {name, tenants}]}'
    EOT
  }
}
