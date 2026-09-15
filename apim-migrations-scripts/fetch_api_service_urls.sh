#!/usr/bin/env bash
set -euo pipefail

OUTPUT_FILE="apim-source-prem-mig-01_api_service_urls.csv"

SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
RESOURCE_GROUP="rg-apim-source-migration"
APIM_NAME="apim-source-prem-mig-01"

echo "Fetching API definitions from APIM: $APIM_NAME..."

echo "api_definition_name,service_url" > "$OUTPUT_FILE"

az rest \
  --method get \
  --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.ApiManagement/service/$APIM_NAME/apis?api-version=2023-05-01-preview&\$top=500" \
  --query "value[?properties.serviceUrl != null].{name:properties.displayName,url:properties.serviceUrl}" \
  --output json |
jq -r '.[] | [.name, .url] | @csv' >> "$OUTPUT_FILE"

COUNT=$(tail -n +2 "$OUTPUT_FILE" | wc -l | xargs)
echo "Exported $COUNT API definitions to: $OUTPUT_FILE"
