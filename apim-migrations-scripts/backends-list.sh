#!/usr/bin/env bash
set -euo pipefail

OUTPUT_FILE="apim-source-prem-mig-01_source_backends.csv"

SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
RESOURCE_GROUP="rg-apim-source-migration"
APIM_NAME="apim-source-prem-mig-01"

echo "backend_name,url" > "$OUTPUT_FILE"

az rest \
  --method get \
  --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.ApiManagement/service/$APIM_NAME/backends?api-version=2023-05-01-preview" \
  --query "value[].{name:name,url:properties.url}" \
  --output json |
jq -r '.[] | [.name, .url] | @csv' >> "$OUTPUT_FILE"

echo "Exported: $OUTPUT_FILE"
