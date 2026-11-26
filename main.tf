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

locals {
  org_id = "38907341-741d-42af-9073-41741de2af61"
  env_id = "b8135005-7573-4ed5-9350-0575739ed56a"

  api_definition = {
    name              = "API 2.8 IaC - Jesus Espi"
    apiVersion        = "1.0.0"
    definitionVersion = "V4"
    type              = "PROXY"
    description       = "Deployed automatically via Terraform CI/CD"
    tags              = ["private"]
    listeners = [
      {
        type = "HTTP"
        paths = [
          {
            path = "/iac-api-jesus-espi"
          }
        ]
        entrypoints = [
          {
            type = "http-proxy"
          }
        ]
      }
    ]
    endpointGroups = [
      {
        name = "default-http-group"
        type = "http-proxy"
        endpoints = [
          {
            name                 = "eu-tenant-endpoint"
            type                 = "http-proxy"
            weight               = 1
            inheritConfiguration = false
            tenants              = ["eu"]
            configuration = {
              target = "https://jsonplaceholder.typicode.com/users/1"
            }
          },
          {
            name                 = "default-fallback-endpoint"
            type                 = "http-proxy"
            weight               = 1
            secondary            = true
            inheritConfiguration = false
            configuration = {
              target = "https://api.gravitee.io/echo"
            }
          }
        ]
      }
    ]
  }

  plan_definition = {
    name              = "Keyless IaC Plan"
    definitionVersion = "V4"
    mode              = "STANDARD"
    validation        = "AUTO"
    security = {
      type = "KEY_LESS"
    }
  }
}

resource "terraform_data" "gravitee_apiv4_deployment" {
  triggers_replace = [
    sha256(jsonencode(local.api_definition))
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      BASE_URL="${var.server_url}/v2/environments/${local.env_id}"

      echo "1. Creating V4 API with sharding tag and tenant rules..."
      API_RESPONSE=$(curl -sS -w "\n%%{http_code}" -X POST "$BASE_URL/apis" \
        -H "Authorization: Bearer ${var.sa_token}" \
        -H "Content-Type: application/json" \
        -d '${jsonencode(local.api_definition)}')

      HTTP_CODE=$(echo "$API_RESPONSE" | tail -n1)
      BODY=$(echo "$API_RESPONSE" | sed '$d')
      echo "API Create Status: $HTTP_CODE"
      if [ "$HTTP_CODE" -ge 300 ]; then echo "$BODY"; exit 1; fi

      API_ID=$(echo "$BODY" | jq -r '.id')
      echo "Created API ID: $API_ID"

      echo "2. Creating and publishing Keyless Plan..."
      PLAN_RESPONSE=$(curl -sS -X POST "$BASE_URL/apis/$API_ID/plans" \
        -H "Authorization: Bearer ${var.sa_token}" \
        -H "Content-Type: application/json" \
        -d '${jsonencode(local.plan_definition)}')
      PLAN_ID=$(echo "$PLAN_RESPONSE" | jq -r '.id')

      curl -sS -X POST "$BASE_URL/apis/$API_ID/plans/$PLAN_ID/_publish" \
        -H "Authorization: Bearer ${var.sa_token}" > /dev/null

      echo "3. Starting and deploying API to designated gateway..."
      curl -sS -X POST "$BASE_URL/apis/$API_ID/_start" \
        -H "Authorization: Bearer ${var.sa_token}" > /dev/null
    EOT
  }
}
