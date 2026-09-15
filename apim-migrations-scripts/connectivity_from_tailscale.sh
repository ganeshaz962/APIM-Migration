#!/usr/bin/env bash
set -euo pipefail

INPUT_FILE="${1:-source_backends.csv}"

PASS_TMP=$(mktemp)
FAIL_TMP=$(mktemp)

tail -n +2 "$INPUT_FILE" | while IFS=',' read -r backend_name url; do
  backend_name="$(echo "$backend_name" | tr -d '"' | xargs)"
  url="$(echo "$url" | tr -d '"' | xargs)"
  [[ -z "$backend_name" || -z "$url" ]] && continue

  # Connection-only check:
  # curl exits 0 if it can resolve, connect, and complete TLS (any HTTP response
  # code counts as success — we only care about reachability, not response status).
  # Non-zero exit codes cover: DNS failure (6), connection refused (7),
  # timeout (28), TLS errors (35/60), etc.
  if curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 12 "$url" \
      > /dev/null 2>&1; then
    echo "$backend_name,$url" >> "$PASS_TMP"
  else
    echo "$backend_name,$url" >> "$FAIL_TMP"
  fi
done

echo "pass:"
if [[ -s "$PASS_TMP" ]]; then
  while IFS=',' read -r name url; do
    echo "- $name -> $url"
  done < "$PASS_TMP"
else
  echo "- None"
fi

echo ""
echo "fail:"
if [[ -s "$FAIL_TMP" ]]; then
  while IFS=',' read -r name url; do
    echo "- $name -> $url"
  done < "$FAIL_TMP"
else
  echo "- None"
fi

rm -f "$PASS_TMP" "$FAIL_TMP"
