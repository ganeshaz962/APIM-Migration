#!/bin/bash
# =============================================================================
# migrate_apim_namedvalues_to_kv.sh
#
# PURPOSE:
#   Extracts SECRET named values from a source APIM (which APIOps masks as *****)
#   Pushes them to an Azure Key Vault (any subscription)
#   Creates Key Vault-referenced named values in the target APIM WORKSPACE
#
# WORKSPACE SUPPORT:
#   Named values in an APIM Workspace use a different REST path:
#     /service/{apim}/workspaces/{workspace}/namedValues
#
# FLEXIBLE KEY VAULT SUBSCRIPTION:
#   KV_SUBSCRIPTION_ID is independent of both SOURCE and TARGET.
#   ┌─────────────────────────────────────────────────────────┐
#   │  PROD  : KV_SUBSCRIPTION_ID = SOURCE_SUBSCRIPTION_ID    │
#   │  TEST  : KV_SUBSCRIPTION_ID = any 3rd subscription      │
#   └─────────────────────────────────────────────────────────┘
#   Just set KV_SUBSCRIPTION_ID to whichever sub your KV lives in.
#
# PREREQUISITES:
#   - Azure CLI installed and logged in (az login)
#   - Logged-in identity must have:
#       Source APIM sub : "API Management Service Reader" + "Operator"
#       KV sub          : "Key Vault Secrets Officer"
#       Target APIM sub : "API Management Service Contributor"
#   - jq installed (brew install jq)
#
# COMPATIBILITY:
#   Works on macOS Bash 3.2+ (no associative arrays). Also works on Bash 4/5.
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION — fill these in before running
# ─────────────────────────────────────────────────────────────────────────────

# SOURCE (Source Premium APIM — global/non-workspace APIs)
SOURCE_SUBSCRIPTION_ID="874a43ac-9423-4b7e-b030-b6023db7be8b"
SOURCE_RESOURCE_GROUP="rg-apim-source-migration"
SOURCE_APIM_NAME="apim-source-prem-mig-01"

# TARGET (Destination APIM workspace)
TARGET_SUBSCRIPTION_ID="874a43ac-9423-4b7e-b030-b6023db7be8b"
TARGET_RESOURCE_GROUP="rg-apim-dest-migration"
TARGET_APIM_NAME="apim-dest-migration-prem"
TARGET_WORKSPACE_NAME="workspace-core-services" # ← APIM Workspace name

# KEY VAULT — must exist beforehand; can live in any subscription
KV_SUBSCRIPTION_ID="874a43ac-9423-4b7e-b030-b6023db7be8b"
KV_RESOURCE_GROUP="rg-apim-migration-shared"
TARGET_KEYVAULT_NAME="kv-apim-migration-nv"


# Optional: prefix for KV secret names to avoid collisions (e.g. "apim-")
KV_SECRET_PREFIX=""

# Optional: only migrate named values whose displayName starts with this (blank = ALL)
NV_FILTER_PREFIX=""

# ─────────────────────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────────────────────

log()    { echo -e "\n\033[1;34m[INFO]\033[0m $*"; }
success(){ echo -e "\033[1;32m[OK]\033[0m $*"; }
warn()   { echo -e "\033[1;33m[WARN]\033[0m $*"; }
error()  { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }

# Switch subscription and print a clear message
switch_sub() {
  local label="$1" sub="$2"
  echo -e "  \033[0;36m[switch → $label]\033[0m $sub"
  az account set --subscription "$sub"
}

# Sanitise a display name -> valid Key Vault secret name
# KV allows: alphanumeric + hyphens, max 127 chars
sanitise_kv_name() {
  echo "${KV_SECRET_PREFIX}${1}" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9-]/-/g' \
    | sed 's/--*/-/g' \
    | cut -c1-127
}

# Temp file used instead of associative array (Bash 3.2 compatible)
# Format per line:  DISPLAY_NAME<TAB>KV_SECRET_URI
NV_MAP_FILE=$(mktemp /tmp/nv_map.XXXXXX)   # KV-secret NVs:   DISPLAY_NAME<TAB>KV_URI
NV_TEXT_FILE=$(mktemp /tmp/nv_text.XXXXXX) # Plain-text NVs:  one JSON object per line
NV_COUNT=0
TEXT_NV_COUNT=0

# Clean up temp files on exit
trap 'rm -f "$NV_MAP_FILE" "$NV_TEXT_FILE"' EXIT

# ─────────────────────────────────────────────────────────────────────────────
# STEP 0: Validate tools + print config summary
# ─────────────────────────────────────────────────────────────────────────────

log "Checking prerequisites..."
command -v az   >/dev/null 2>&1 || { error "Azure CLI not found. Install: https://aka.ms/installazurecli"; exit 1; }
command -v jq   >/dev/null 2>&1 || { error "jq not found. Run: brew install jq"; exit 1; }
command -v curl >/dev/null 2>&1 || { error "curl not found."; exit 1; }
success "Prerequisites OK"

echo ""
echo "  Bash version    : $BASH_VERSION"
echo "  ┌─ Source APIM  : $SOURCE_APIM_NAME"
echo "  │  Subscription : $SOURCE_SUBSCRIPTION_ID"
echo "  ├─ Key Vault    : $TARGET_KEYVAULT_NAME"
echo "  │  Subscription : $KV_SUBSCRIPTION_ID"
if [ "$KV_SUBSCRIPTION_ID" = "$SOURCE_SUBSCRIPTION_ID" ]; then
  echo "  │  (same as source — PROD mode)"
elif [ "$KV_SUBSCRIPTION_ID" = "$TARGET_SUBSCRIPTION_ID" ]; then
  echo "  │  (same as target)"
else
  echo "  │  (3rd subscription — TEST mode)"
fi
echo "  └─ Target APIM  : $TARGET_APIM_NAME / $TARGET_WORKSPACE_NAME"
echo "     Subscription : $TARGET_SUBSCRIPTION_ID"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1: Switch to source subscription and get ARM token
# ─────────────────────────────────────────────────────────────────────────────

log "Switching to SOURCE subscription..."
switch_sub "source" "$SOURCE_SUBSCRIPTION_ID"

ARM_TOKEN=$(az account get-access-token \
  --resource "https://management.azure.com/" \
  --query accessToken -o tsv)

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2: List all named values from source APIM
# ─────────────────────────────────────────────────────────────────────────────

log "Listing named values from source APIM: $SOURCE_APIM_NAME"

API_VERSION="2022-08-01"
SOURCE_BASE_URL="https://management.azure.com/subscriptions/${SOURCE_SUBSCRIPTION_ID}/resourceGroups/${SOURCE_RESOURCE_GROUP}/providers/Microsoft.ApiManagement/service/${SOURCE_APIM_NAME}"

NV_LIST=$(curl -s -X GET \
  "${SOURCE_BASE_URL}/namedValues?api-version=${API_VERSION}&\$top=1000" \
  -H "Authorization: Bearer ${ARM_TOKEN}" \
  -H "Content-Type: application/json")

if echo "$NV_LIST" | jq -e '.error' > /dev/null 2>&1; then
  error "Failed to list named values: $(echo "$NV_LIST" | jq -r '.error.message')"
  exit 1
fi

TOTAL=$(echo "$NV_LIST" | jq '.value | length')
log "Found $TOTAL named value(s) in source APIM"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3: For each secret named value — reveal real value, push to KV
# ─────────────────────────────────────────────────────────────────────────────

log "Processing named values..."
echo "──────────────────────────────────────────────────────"

while IFS= read -r nv; do
  NV_NAME=$(echo "$nv"      | jq -r '.name')
  DISPLAY_NAME=$(echo "$nv" | jq -r '.properties.displayName')
  IS_SECRET=$(echo "$nv"    | jq -r '.properties.secret')

  # Optional prefix filter (Bash 3.2 compatible)
  if [ -n "$NV_FILTER_PREFIX" ]; then
    case "$DISPLAY_NAME" in
      ${NV_FILTER_PREFIX}*) ;;
      *)
        warn "Skipping '$DISPLAY_NAME' (no match for prefix '$NV_FILTER_PREFIX')"
        continue
        ;;
    esac
  fi

  # Handle plain text (non-secret) named values — copy value directly to target
  # [COMMENTED OUT] — only pushing secrets to KV; target APIM creation disabled
  # if [ "$IS_SECRET" != "true" ]; then
  #   PLAIN_VALUE=$(echo "$nv" | jq -r '.properties.value // empty')
  #   if [ -z "$PLAIN_VALUE" ]; then
  #     warn "  '$DISPLAY_NAME' — plain text value is empty, skipping"
  #     continue
  #   fi
  #   log "Queuing TEXT: '$DISPLAY_NAME'"
  #   # Store as compact single-line JSON (jq -c) so the file can be read line-by-line later
  #   jq -cn --arg n "$NV_NAME" --arg d "$DISPLAY_NAME" --arg v "$PLAIN_VALUE" '{n:$n,d:$d,v:$v}' >> "$NV_TEXT_FILE"
  #   TEXT_NV_COUNT=$((TEXT_NV_COUNT + 1))
  #   continue
  # fi
  if [ "$IS_SECRET" != "true" ]; then
    warn "  '$DISPLAY_NAME' — plain text NV skipped (only pushing secrets to KV)"
    continue
  fi

  log "Processing SECRET: '$DISPLAY_NAME'"

  # ── 3a. Source sub: reveal actual secret via listValue ──────────────────────
  switch_sub "source" "$SOURCE_SUBSCRIPTION_ID"
  ARM_TOKEN=$(az account get-access-token \
    --resource "https://management.azure.com/" \
    --query accessToken -o tsv)

  SECRET_RESPONSE=$(curl -s -X POST \
    "${SOURCE_BASE_URL}/namedValues/${NV_NAME}/listValue?api-version=${API_VERSION}" \
    -H "Authorization: Bearer ${ARM_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{}')

  if echo "$SECRET_RESPONSE" | jq -e '.error' > /dev/null 2>&1; then
    error "  Could not retrieve value for '$DISPLAY_NAME': $(echo "$SECRET_RESPONSE" | jq -r '.error.message')"
    continue
  fi

  SECRET_VALUE=$(echo "$SECRET_RESPONSE" | jq -r '.value')

  if [ -z "$SECRET_VALUE" ] || [ "$SECRET_VALUE" = "null" ]; then
    warn "  Empty value for '$DISPLAY_NAME' — skipping"
    continue
  fi

  # ── 3b. KV sub: push secret to Key Vault ────────────────────────────────────
  switch_sub "keyvault" "$KV_SUBSCRIPTION_ID"

  KV_SECRET_NAME=$(sanitise_kv_name "$NV_NAME")

  log "  Pushing to KV [$TARGET_KEYVAULT_NAME] as: '$KV_SECRET_NAME'"
  az keyvault secret set \
    --vault-name "$TARGET_KEYVAULT_NAME" \
    --name       "$KV_SECRET_NAME" \
    --value      "$SECRET_VALUE" \
    --output none

  # Versionless URI — APIM auto-rotates when KV secret is updated
  KV_SECRET_URI=$(az keyvault secret show \
    --vault-name "$TARGET_KEYVAULT_NAME" \
    --name       "$KV_SECRET_NAME" \
    --query "id" -o tsv | sed 's|/[^/]*$||')

  success "  Stored: $KV_SECRET_URI"

  # Save mapping as tab-separated line (replaces declare -A, Bash 3.2 safe)
  printf '%s\t%s\n' "$DISPLAY_NAME" "$KV_SECRET_URI" >> "$NV_MAP_FILE"
  NV_COUNT=$((NV_COUNT + 1))

done < <(echo "$NV_LIST" | jq -c '.value[]')

echo "──────────────────────────────────────────────────────"
log "Key Vault push complete. $NV_COUNT secret(s) stored."

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4: Grant target APIM managed identity access to Key Vault
# [COMMENTED OUT] — not needed; only pushing secrets to KV from source APIM
# ─────────────────────────────────────────────────────────────────────────────

# log "Granting target APIM managed identity access to Key Vault..."
#
# # ── 4a. Get the APIM principal ID (target sub) ──────────────────────────────
# switch_sub "target APIM" "$TARGET_SUBSCRIPTION_ID"
#
# APIM_PRINCIPAL_ID=$(az apim show \
#   --name           "$TARGET_APIM_NAME" \
#   --resource-group "$TARGET_RESOURCE_GROUP" \
#   --query          "identity.principalId" \
#   -o tsv 2>/dev/null || echo "")
#
# if [ -z "$APIM_PRINCIPAL_ID" ]; then
#   warn "Managed identity not found on target APIM. Enable it first, then re-run:"
#   warn "  az apim update --name $TARGET_APIM_NAME --resource-group $TARGET_RESOURCE_GROUP --enable-managed-identity true"
# else
#   # ── 4b. Switch to KV sub to create the role assignment ──────────────────────
#   switch_sub "keyvault" "$KV_SUBSCRIPTION_ID"
#
#   KV_RESOURCE_ID=$(az keyvault show \
#     --name            "$TARGET_KEYVAULT_NAME" \
#     --resource-group  "$KV_RESOURCE_GROUP" \
#     --query id -o tsv)
#
#   az role assignment create \
#     --role                    "Key Vault Secrets User" \
#     --assignee-object-id      "$APIM_PRINCIPAL_ID" \
#     --assignee-principal-type ServicePrincipal \
#     --scope                   "$KV_RESOURCE_ID" \
#     --output none 2>/dev/null \
#     && success "Role 'Key Vault Secrets User' assigned to APIM managed identity on KV" \
#     || warn "Role assignment may already exist — verify in portal if unsure"
# fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5: Validate workspace exists in target APIM
# [COMMENTED OUT] — not needed; only pushing secrets to KV from source APIM
# ─────────────────────────────────────────────────────────────────────────────

# log "Validating workspace '$TARGET_WORKSPACE_NAME' in target APIM..."
#
# switch_sub "target APIM" "$TARGET_SUBSCRIPTION_ID"
#
# ARM_TOKEN_TARGET=$(az account get-access-token \
#   --resource "https://management.azure.com/" \
#   --query accessToken -o tsv)
#
# WORKSPACE_CHECK=$(curl -s -X GET \
#   "https://management.azure.com/subscriptions/${TARGET_SUBSCRIPTION_ID}/resourceGroups/${TARGET_RESOURCE_GROUP}/providers/Microsoft.ApiManagement/service/${TARGET_APIM_NAME}/workspaces/${TARGET_WORKSPACE_NAME}?api-version=${API_VERSION}" \
#   -H "Authorization: Bearer ${ARM_TOKEN_TARGET}" \
#   -H "Content-Type: application/json")
#
# if echo "$WORKSPACE_CHECK" | jq -e '.error' > /dev/null 2>&1; then
#   error "Workspace '$TARGET_WORKSPACE_NAME' not found in '$TARGET_APIM_NAME'."
#   error "$(echo "$WORKSPACE_CHECK" | jq -r '.error.message')"
#   error "Create the workspace in the portal first, then re-run."
#   exit 1
# fi
# success "Workspace '$TARGET_WORKSPACE_NAME' confirmed."

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6: Create KV-referenced named values in the target APIM WORKSPACE
# [COMMENTED OUT] — not needed; only pushing secrets to KV from source APIM
# ─────────────────────────────────────────────────────────────────────────────

# log "Creating named values in workspace: $TARGET_APIM_NAME / $TARGET_WORKSPACE_NAME"
# echo "──────────────────────────────────────────────────────"
#
# TARGET_BASE_URL="https://management.azure.com/subscriptions/${TARGET_SUBSCRIPTION_ID}/resourceGroups/${TARGET_RESOURCE_GROUP}/providers/Microsoft.ApiManagement/service/${TARGET_APIM_NAME}/workspaces/${TARGET_WORKSPACE_NAME}"
#
# CREATED=0
# FAILED=0
#
# # Read tab-separated map file line by line (Bash 3.2 compatible)
# while IFS="	" read -r DISPLAY_NAME KV_URI; do
#
#   [ -z "$DISPLAY_NAME" ] && continue
#
#   RESOURCE_NAME=$(echo "$DISPLAY_NAME" \
#     | tr '[:upper:]' '[:lower:]' \
#     | sed 's/[^a-z0-9-]/-/g' \
#     | sed 's/--*/-/g' \
#     | cut -c1-80)
#
#   log "Creating: '$DISPLAY_NAME'"
#
#   PAYLOAD=$(jq -n \
#     --arg displayName "$DISPLAY_NAME" \
#     --arg kvUri       "$KV_URI" \
#     '{
#       properties: {
#         displayName: $displayName,
#         secret: true,
#         keyVault: {
#           secretIdentifier: $kvUri
#         }
#       }
#     }')
#
#   # Refresh token on every named value (prevents expiry on large migrations)
#   ARM_TOKEN_TARGET=$(az account get-access-token \
#     --resource "https://management.azure.com/" \
#     --query accessToken -o tsv)
#
#   RESULT=$(curl -s -X PUT \
#     "${TARGET_BASE_URL}/namedValues/${RESOURCE_NAME}?api-version=${API_VERSION}" \
#     -H "Authorization: Bearer ${ARM_TOKEN_TARGET}" \
#     -H "Content-Type: application/json" \
#     -d "$PAYLOAD")
#
#   if echo "$RESULT" | jq -e '.error' > /dev/null 2>&1; then
#     error "  FAILED '$DISPLAY_NAME': $(echo "$RESULT" | jq -r '.error.message')"
#     FAILED=$((FAILED + 1))
#   else
#     success "  Created: '$DISPLAY_NAME' (KV-referenced)"
#     CREATED=$((CREATED + 1))
#   fi
#
# done < "$NV_MAP_FILE"
#
# # ── Plain text named values ──────────────────────────────────────────────────
# if [ -s "$NV_TEXT_FILE" ]; then
#   log "Creating plain text named values in workspace: $TARGET_APIM_NAME / $TARGET_WORKSPACE_NAME"
#   echo "──────────────────────────────────────────────────────"
#
#   switch_sub "target APIM" "$TARGET_SUBSCRIPTION_ID"
#
#   while IFS= read -r line; do
#     [ -z "$line" ] && continue
#
#     PT_NV_NAME=$(echo "$line"    | jq -r '.n')
#     PT_DISPLAY=$(echo "$line"    | jq -r '.d')
#     PT_VALUE=$(echo "$line"      | jq -r '.v')
#
#     log "Creating TEXT: '$PT_DISPLAY'"
#
#     PAYLOAD=$(jq -n \
#       --arg displayName "$PT_DISPLAY" \
#       --arg value       "$PT_VALUE" \
#       '{
#         properties: {
#           displayName: $displayName,
#           value: $value,
#           secret: false
#         }
#       }')
#
#     # Refresh token on every named value (prevents expiry on large migrations)
#     ARM_TOKEN_TARGET=$(az account get-access-token \
#       --resource "https://management.azure.com/" \
#       --query accessToken -o tsv)
#
#     RESULT=$(curl -s -X PUT \
#       "${TARGET_BASE_URL}/namedValues/${PT_NV_NAME}?api-version=${API_VERSION}" \
#       -H "Authorization: Bearer ${ARM_TOKEN_TARGET}" \
#       -H "Content-Type: application/json" \
#       -d "$PAYLOAD")
#
#     if echo "$RESULT" | jq -e '.error' > /dev/null 2>&1; then
#       error "  FAILED '$PT_DISPLAY': $(echo "$RESULT" | jq -r '.error.message')"
#       FAILED=$((FAILED + 1))
#     else
#       success "  Created: '$PT_DISPLAY' (plain text)"
#       CREATED=$((CREATED + 1))
#     fi
#
#   done < "$NV_TEXT_FILE"
# fi

# ─────────────────────────────────────────────────────────────────────────────
# DONE
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "══════════════════════════════════════════════════════"
log "KV push complete!"
echo ""
echo "  Secrets pushed to Key Vault  : $NV_COUNT"
echo "  Key Vault                    : $TARGET_KEYVAULT_NAME  [$KV_SUBSCRIPTION_ID]"
echo "  Source APIM                  : $SOURCE_APIM_NAME"
echo "══════════════════════════════════════════════════════"
echo ""
echo "Next steps:"
echo "  1. Verify secrets in Key Vault: $TARGET_KEYVAULT_NAME"
echo "  2. Run Step 4-6 separately when ready to create named values in target APIM"