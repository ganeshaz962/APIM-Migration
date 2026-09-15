#!/usr/bin/env bash

RESOURCE_GROUP="rg-apim-source-migration"
APIM_NAME="apim-source-prem-mig-01"
BACKENDS_FILE="backends.csv"
OUTPUT_FILE="connectivity_report.csv"

PASS_TMP=$(mktemp)
FAIL_TMP=$(mktemp)

echo "Fetching backends from APIM: $APIM_NAME..."

echo "backend_name,url" > "$BACKENDS_FILE"

az apim backend list \
  --resource-group "$RESOURCE_GROUP" \
  --service-name "$APIM_NAME" \
  --query "[].{name:name, url:url}" \
  --output json | \
jq -r '.[] | [.name, .url] | @csv' >> "$BACKENDS_FILE"

echo "Found $(tail -n +2 "$BACKENDS_FILE" | wc -l) backends. Checking connectivity..."
echo ""

tail -n +2 "$BACKENDS_FILE" | while IFS=',' read -r backend_name url; do
  backend_name="$(echo "$backend_name" | xargs | tr -d '"')"
  url="$(echo "$url" | xargs | tr -d '"')"

  [[ -z "$backend_name" || -z "$url" ]] && continue

  http_code=$(curl -sS -o /dev/null --connect-timeout 5 --max-time 10 -w "%{http_code}" "$url" 2>/dev/null)

  if [[ "$http_code" =~ ^(200|201|204|301|302)$ ]]; then
    echo "$backend_name,$url" >> "$PASS_TMP"
  else
    echo "$backend_name,$url,FAIL (HTTP $http_code)" >> "$FAIL_TMP"
  fi
done

# Console output
echo "PASS:"
while IFS=',' read -r name url; do
  echo "  - $name → $url"
done < "$PASS_TMP"

echo ""
echo "FAIL:"
while IFS=',' read -r name url reason; do
  echo "  - $name → $url [$reason]"
done < "$FAIL_TMP"

# CSV output (PASS first, FAIL last)
echo "backend_name,url,status" > "$OUTPUT_FILE"
while IFS=',' read -r name url; do
  echo "\"$name\",\"$url\",\"PASS\"" >> "$OUTPUT_FILE"
done < "$PASS_TMP"

while IFS=',' read -r name url reason; do
  echo "\"$name\",\"$url\",\"$reason\"" >> "$OUTPUT_FILE"
done < "$FAIL_TMP"

rm -f "$PASS_TMP" "$FAIL_TMP"

echo ""
echo "Report saved to: $OUTPUT_FILE"
