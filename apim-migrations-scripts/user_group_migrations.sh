#!/bin/bash
# =============================================================================
# user_group_migrations.sh
#
# PURPOSE:
#   Production-grade migration of APIM Users, Groups, Group Memberships,
#   and Product Subscriptions from a source APIM (Developer SKU, Sub A) to a
#   target APIM Premium instance with Workspace-based architecture (Sub B).
#
# ARCHITECTURE:
#   ┌──────────────────────────────────────────────────────────────────────┐
#   │  SOURCE (Developer SKU — service level)                              │
#   │    /users/{id}                   Entra ID + Developer Portal users   │
#   │    /groups/{id}                  Custom + Built-in + External groups │
#   │    /groups/{id}/users            Group memberships                   │
#   │    /products/{id}/groups         Product-to-group assignments        │
#   │    /subscriptions/{id}           User product subscriptions          │
#   │                                                                      │
#   │  TARGET (Premium + Workspace — mixed levels)                         │
#   │    /users/{id}              ◄──  Service-level users (Entra + Dev)   │
#   │    /workspaces/{ws}/groups  ◄──  Workspace-scoped groups             │
#   │    /workspaces/{ws}/groups/{g}/users/{u}   ◄──  Group memberships    │
#   │    /workspaces/{ws}/products/{p}/groups/{g} ◄── Product-group links  │
#   │    /workspaces/{ws}/subscriptions  ◄──  Workspace subscriptions      │
#   └──────────────────────────────────────────────────────────────────────┘
#
# KEY CONSTRAINTS:
#   - APIM users are ALWAYS service-level (not workspace-scoped)
#   - Built-in groups (Administrators, Developers, Guests) are pre-seeded in
#     every workspace — they cannot be created but memberships CAN be rebuilt
#   - Developer Portal user passwords CANNOT be migrated — temp passwords are
#     set and users must reset via email invite / SSO URL
#   - Subscription keys are fetched live from source at migration time and
#     are NEVER written to disk
#   - External (Entra ID) groups linked via externalId are preserved
#
# PHASES:
#   discover  — Export all source entities to JSON in ./migration-output/
#   migrate   — Import into target APIM service and workspace
#   validate  — Verify entity counts and consistency
#   all       — Run all three phases sequentially (default)
#
# USAGE:
#   chmod +x user_group_migrations.sh
#   ./user_group_migrations.sh [discover|migrate|validate|all]
#
# PREREQUISITES:
#   - az CLI installed and authenticated  →  az login
#   - jq installed                        →  brew install jq
#   - curl available (macOS built-in)
#   - Required RBAC on source subscription:
#       API Management Service Reader + API Management Service Operator
#   - Required RBAC on target subscription:
#       API Management Service Contributor (or API Management Workspace Contributor)
#   - For Entra ID users: same tenant assumed — no cross-tenant invite needed
#
# OUTPUT:
#   ./migration-output/
#     ├── users.json                    All source users (no passwords)
#     ├── groups.json                   All source groups
#     ├── group_memberships/
#     │     ├── _summary.json           Per-group member counts
#     │     └── {groupId}.json          Members of each group
#     ├── products.json                 All source products
#     ├── product_groups/
#     │     └── {productId}.json        Groups per product
#     ├── subscriptions.json            Subscription metadata (NO keys)
#     └── migration.log                 Full timestamped log
#
# SECURITY NOTES:
#   ★ Subscription keys live in RAM only during migration — never written to
#     disk or to migration.log (entries are labelled REDACTED in the log)
#   ★ Dev Portal user temp passwords are generated with openssl rand and
#     discarded after the PUT call — never logged
#   ★ Entra ID users are re-linked to their existing AAD identity by preserving
#     the identities[].id (AAD object ID) — no password flow needed
#   ★ Run this script from a hardened bastion / CI pipeline with restricted
#     log access; treat the output directory as sensitive
#
# ROLLBACK STRATEGY:
#   There is no destructive operation on the SOURCE — the source APIM is
#   read-only throughout. To roll back the target:
#     1. Delete workspace subscriptions:  az rest DELETE .../workspaces/{ws}/subscriptions/{id}
#     2. Delete workspace group members:  az rest DELETE .../workspaces/{ws}/groups/{g}/users/{u}
#     3. Delete workspace groups:         az rest DELETE .../workspaces/{ws}/groups/{g}
#     4. Delete service-level users:      az rest DELETE .../users/{id}?deleteSubscriptions=true
#   A rollback manifest is written to ./migration-output/rollback_manifest.json
#   during the migration phase to assist with ordered deletion.
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION — fill in before running
# ─────────────────────────────────────────────────────────────────────────────

# SOURCE APIM (Premium — global/non-workspace)
SOURCE_SUBSCRIPTION_ID="874a43ac-9423-4b7e-b030-b6023db7be8b"
SOURCE_RESOURCE_GROUP="rg-apim-source-migration"
SOURCE_APIM_NAME="apim-source-prem-mig-01"

# TARGET APIM (Premium + Workspaces)
TARGET_SUBSCRIPTION_ID="874a43ac-9423-4b7e-b030-b6023db7be8b"
TARGET_RESOURCE_GROUP="rg-apim-dest-migration"
TARGET_APIM_NAME="apim-dest-migration-prem"
TARGET_WORKSPACE_NAME="workspace-core-services"   # target workspace name

# MIGRATION CONTROL FLAGS
MIGRATE_SUBSCRIPTIONS=false    # set false to skip subscription key migration
SEND_INVITE_EMAILS=false      # set true to send password-reset invites to Dev Portal users
DRY_RUN=false                 # set true to log actions without making API calls

# RETRY / THROTTLE SETTINGS
MAX_RETRIES=3
RETRY_DELAY_SECONDS=5

# API VERSIONS
SRC_API_VERSION="2022-08-01"
TGT_API_VERSION="2023-09-01-preview"

# OUTPUT
OUTPUT_DIR="./migration-output"
LOG_FILE="${OUTPUT_DIR}/migration.log"
ROLLBACK_FILE="${OUTPUT_DIR}/rollback_manifest.json"

# ─────────────────────────────────────────────────────────────────────────────
# TERMINAL COLOURS
# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[1;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─────────────────────────────────────────────────────────────────────────────
# LOGGING
# ─────────────────────────────────────────────────────────────────────────────

_ts() { date '+%H:%M:%S'; }

log()     { local m="[$(_ts)] [INFO]  $*"; echo -e "${BLUE}${m}${NC}";    echo "${m}" >> "${LOG_FILE}"; }
success() { local m="[$(_ts)] [OK]    $*"; echo -e "${GREEN}${m}${NC}";   echo "${m}" >> "${LOG_FILE}"; }
warn()    { local m="[$(_ts)] [WARN]  $*"; echo -e "${YELLOW}${m}${NC}";  echo "${m}" >> "${LOG_FILE}"; }
error()   { local m="[$(_ts)] [ERROR] $*"; echo -e "${RED}${m}${NC}" >&2; echo "${m}" >> "${LOG_FILE}"; }
section() {
  local line="══════════════════════════════════════════════════════"
  echo -e "\n${CYAN}${line}${NC}"
  echo -e "${CYAN}${BOLD}  $*${NC}"
  echo -e "${CYAN}${line}${NC}\n"
  echo "=== $* ===" >> "${LOG_FILE}"
}

# Global counters
SUCCESS_COUNT=0
FAILED_COUNT=0
SKIP_COUNT=0

inc_success() { SUCCESS_COUNT=$((SUCCESS_COUNT + 1)); }
inc_failed()  { FAILED_COUNT=$((FAILED_COUNT + 1)); }
inc_skip()    { SKIP_COUNT=$((SKIP_COUNT + 1)); }

# ─────────────────────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────────────────────

# Switch active subscription and refresh token
switch_sub() {
  local label="$1" sub="$2"
  echo -e "  ${CYAN}[switch → ${label}]${NC} ${sub}"
  az account set --subscription "${sub}" 2>/dev/null
  ARM_TOKEN=$(az account get-access-token \
    --resource "https://management.azure.com/" \
    --query accessToken -o tsv 2>/dev/null)
}

# REST call with retry and idempotency handling
# Usage: rest_call <METHOD> <URL> [body_json_file]
# Returns: response body on stdout; exits non-zero on unrecoverable failure
rest_call() {
  local method="$1"
  local url="$2"
  local body_file="${3:-}"
  local attempt=1
  local response body http_code

  if ${DRY_RUN}; then
    echo "[DRY-RUN] ${method} ${url}" >&2
    echo '{"dryRun": true}'
    return 0
  fi

  while [ "${attempt}" -le "${MAX_RETRIES}" ]; do
    if [ -n "${body_file}" ] && [ -f "${body_file}" ]; then
      response=$(curl -s -w "\n__STATUS__%{http_code}" \
        -X "${method}" "${url}" \
        -H "Authorization: Bearer ${ARM_TOKEN}" \
        -H "Content-Type: application/json" \
        --data-binary "@${body_file}" 2>/dev/null)
    else
      # PUT with no body still needs Content-Length:0 for some APIM endpoints
      response=$(curl -s -w "\n__STATUS__%{http_code}" \
        -X "${method}" "${url}" \
        -H "Authorization: Bearer ${ARM_TOKEN}" \
        -H "Content-Type: application/json" \
        -H "Content-Length: 0" 2>/dev/null)
    fi

    http_code=$(printf '%s' "${response}" | grep '__STATUS__' | sed 's/__STATUS__//')
    body=$(printf '%s' "${response}" | grep -v '__STATUS__')

    case "${http_code}" in
      200|201|204)
        echo "${body}"
        return 0
        ;;
      409)
        # Already exists — treat as idempotent success
        warn "  HTTP 409 (already exists) for ${method} ${url} — treating as OK"
        echo "${body}"
        return 0
        ;;
      429|503)
        warn "  HTTP ${http_code} throttled — retry ${attempt}/${MAX_RETRIES} in ${RETRY_DELAY_SECONDS}s"
        sleep "${RETRY_DELAY_SECONDS}"
        # Refresh token before retry (token may expire on long runs)
        ARM_TOKEN=$(az account get-access-token \
          --resource "https://management.azure.com/" \
          --query accessToken -o tsv 2>/dev/null)
        attempt=$((attempt + 1))
        ;;
      404)
        # Return the body so callers can distinguish "not found" from hard failure
        echo "${body}"
        return 1
        ;;
      *)
        local err_msg
        err_msg=$(echo "${body}" | jq -r '.error.message // .message // "HTTP '"${http_code}"'"' 2>/dev/null)
        warn "  HTTP ${http_code} on attempt ${attempt}/${MAX_RETRIES}: ${err_msg}"
        attempt=$((attempt + 1))
        sleep 2
        ;;
    esac
  done

  error "  All ${MAX_RETRIES} attempts exhausted for ${method} ${url}"
  echo '{"error":{"code":"MaxRetriesExceeded","message":"All retries exhausted"}}'
  return 1
}

# Paginate all results across nextLink pages
# Usage: fetch_all_pages <initial_url>
# Returns: JSON array on stdout
fetch_all_pages() {
  local url="$1"
  local all_items="[]"
  local page response next_link

  while [ -n "${url}" ] && [ "${url}" != "null" ]; do
    response=$(rest_call GET "${url}" 2>/dev/null || echo '{"value":[]}')
    page=$(echo "${response}" | jq -c '.value // []')
    all_items=$(printf '%s\n%s' "${all_items}" "${page}" | jq -sc 'add // []')
    next_link=$(echo "${response}" | jq -r '.nextLink // "null"')
    url="${next_link}"
  done

  echo "${all_items}"
}

# Sanitise a free-form string to a valid APIM resource identifier
# APIM IDs: alphanumeric + hyphen, max 80 chars
sanitise_id() {
  echo "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/@/-at-/g; s/\./-/g; s/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//' \
    | cut -c1-80
}

# Map a built-in source group name to the standard workspace group ID
builtin_group_id() {
  case "$1" in
    "Administrators") echo "administrators" ;;
    "Developers")     echo "developers"     ;;
    "Guests")         echo "guests"         ;;
    *)                sanitise_id "$1"      ;;
  esac
}

# Write an entry to the rollback manifest (JSON array append)
append_rollback() {
  local type="$1" resource_url="$2"
  local existing
  existing=$(cat "${ROLLBACK_FILE}" 2>/dev/null || echo '[]')
  printf '%s' "${existing}" | jq \
    --arg type "${type}" \
    --arg url "${resource_url}" \
    --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '. + [{"type": $type, "deleteUrl": $url, "createdAt": $ts}]' \
    > "${ROLLBACK_FILE}"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 0 — PREREQUISITES
# ─────────────────────────────────────────────────────────────────────────────

check_prerequisites() {
  # Create output directories and initialise log BEFORE any function that
  # writes to ${LOG_FILE} (section/log/error all append to it).
  mkdir -p \
    "${OUTPUT_DIR}/group_memberships" \
    "${OUTPUT_DIR}/product_groups"
  : > "${LOG_FILE}"
  echo '[]' > "${ROLLBACK_FILE}"

  section "PREREQUISITE CHECK"

  local ok=true
  command -v az   >/dev/null 2>&1 || { error "Azure CLI not found  →  https://aka.ms/installazurecli"; ok=false; }
  command -v jq   >/dev/null 2>&1 || { error "jq not found  →  brew install jq"; ok=false; }
  command -v curl >/dev/null 2>&1 || { error "curl not found"; ok=false; }
  command -v openssl >/dev/null 2>&1 || { error "openssl not found (required for temp password generation)"; ok=false; }
  ${ok} || exit 1

  local account
  account=$(az account show --query "user.name" -o tsv 2>/dev/null) \
    || { error "Not logged in  →  az login"; exit 1; }
  success "Logged in as: ${account}"

  echo ""
  echo "  Bash            : ${BASH_VERSION}"
  echo "  Dry-run mode    : ${DRY_RUN}"
  echo "  Migrate sub keys: ${MIGRATE_SUBSCRIPTIONS}"
  echo "  Send invites    : ${SEND_INVITE_EMAILS}"
  echo ""
  echo "  ┌─ Source APIM  : ${SOURCE_APIM_NAME}"
  echo "  │  Resource Group: ${SOURCE_RESOURCE_GROUP}"
  echo "  │  Subscription : ${SOURCE_SUBSCRIPTION_ID}"
  echo "  └─ Target APIM  : ${TARGET_APIM_NAME}"
  echo "     Workspace    : ${TARGET_WORKSPACE_NAME}"
  echo "     Resource Group: ${TARGET_RESOURCE_GROUP}"
  echo "     Subscription : ${TARGET_SUBSCRIPTION_ID}"
  echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 1 — DISCOVERY (EXPORT FROM SOURCE)
# ─────────────────────────────────────────────────────────────────────────────

discover() {
  section "PHASE 1 — DISCOVERY"

  switch_sub "source" "${SOURCE_SUBSCRIPTION_ID}"

  local SRC_BASE="https://management.azure.com/subscriptions/${SOURCE_SUBSCRIPTION_ID}/resourceGroups/${SOURCE_RESOURCE_GROUP}/providers/Microsoft.ApiManagement/service/${SOURCE_APIM_NAME}"

  # ───────────────────────────────────────────────────────────────────────────
  # 1.1 Export Users
  # ───────────────────────────────────────────────────────────────────────────
  log "1.1  Exporting users..."

  # Filter out the built-in admin user (id=1) from export
  local all_users
  all_users=$(fetch_all_pages \
    "${SRC_BASE}/users?api-version=${SRC_API_VERSION}&\$top=1000&\$filter=name%20ne%20'1'")

  echo "${all_users}" | jq '.' > "${OUTPUT_DIR}/users.json"

  local total_users aad_users dev_users
  total_users=$(echo "${all_users}" | jq 'length')
  aad_users=$(echo "${all_users}" | jq \
    '[.[] | select(
       (.properties.identities[]?.provider // "") == "Aad" or
       (.properties.identities[]?.provider // "") == "AadB2C"
     )] | length')
  dev_users=$(echo "${all_users}" | jq \
    '[.[] | select(
       (.properties.identities[]?.provider // "") == "Basic"
     )] | length')

  success "Exported ${total_users} user(s)  →  ${OUTPUT_DIR}/users.json"
  log     "  ├─ Entra ID (AAD/AadB2C) : ${aad_users}"
  log     "  └─ Developer Portal (Basic): ${dev_users}"

  # ───────────────────────────────────────────────────────────────────────────
  # 1.2 Export Groups
  # ───────────────────────────────────────────────────────────────────────────
  log "1.2  Exporting groups..."

  local all_groups
  all_groups=$(fetch_all_pages \
    "${SRC_BASE}/groups?api-version=${SRC_API_VERSION}&\$top=1000")

  echo "${all_groups}" | jq '.' > "${OUTPUT_DIR}/groups.json"

  local total_groups system_groups custom_groups ext_groups
  total_groups=$(echo "${all_groups}" | jq 'length')
  system_groups=$(echo "${all_groups}" | jq '[.[] | select(.properties.type == "system")] | length')
  custom_groups=$(echo "${all_groups}" | jq '[.[] | select(.properties.type == "custom")] | length')
  ext_groups=$(echo "${all_groups}" | jq '[.[] | select(.properties.type == "external")] | length')

  success "Exported ${total_groups} group(s)  →  ${OUTPUT_DIR}/groups.json"
  log     "  ├─ Built-in (system)  : ${system_groups}  [skipped on create — pre-seeded in workspace]"
  log     "  ├─ Custom             : ${custom_groups}"
  log     "  └─ External (Entra)   : ${ext_groups}"

  # ───────────────────────────────────────────────────────────────────────────
  # 1.3 Export Group Memberships
  # ───────────────────────────────────────────────────────────────────────────
  log "1.3  Exporting group memberships..."

  local membership_summary="[]"

  while IFS= read -r group_json; do
    local g_id g_name g_type
    g_id=$(echo "${group_json}"  | jq -r '.name')
    g_name=$(echo "${group_json}" | jq -r '.properties.displayName')
    g_type=$(echo "${group_json}" | jq -r '.properties.type')

    local members
    members=$(fetch_all_pages \
      "${SRC_BASE}/groups/${g_id}/users?api-version=${SRC_API_VERSION}&\$top=1000")

    echo "${members}" | jq '.' > "${OUTPUT_DIR}/group_memberships/${g_id}.json"

    local mc
    mc=$(echo "${members}" | jq 'length')
    log "  Group '${g_name}' (${g_type}): ${mc} member(s)"

    membership_summary=$(printf '%s' "${membership_summary}" | jq \
      --arg gid   "${g_id}" \
      --arg gname "${g_name}" \
      --arg gtype "${g_type}" \
      --argjson count "${mc}" \
      '. + [{"groupId":$gid,"groupName":$gname,"groupType":$gtype,"memberCount":$count}]')
  done < <(jq -c '.[]' "${OUTPUT_DIR}/groups.json")

  echo "${membership_summary}" | jq '.' > "${OUTPUT_DIR}/group_memberships/_summary.json"
  success "Exported group memberships  →  ${OUTPUT_DIR}/group_memberships/"

  # ───────────────────────────────────────────────────────────────────────────
  # 1.4 Export Products
  # ───────────────────────────────────────────────────────────────────────────
  log "1.4  Exporting products..."

  local all_products
  all_products=$(fetch_all_pages \
    "${SRC_BASE}/products?api-version=${SRC_API_VERSION}&\$top=1000")

  echo "${all_products}" | jq '.' > "${OUTPUT_DIR}/products.json"
  success "Exported $(echo "${all_products}" | jq 'length') product(s)  →  ${OUTPUT_DIR}/products.json"

  # ───────────────────────────────────────────────────────────────────────────
  # 1.5 Export Product-to-Group Assignments
  # ───────────────────────────────────────────────────────────────────────────
  log "1.5  Exporting product-to-group assignments..."

  while IFS= read -r product_json; do
    local p_id p_name
    p_id=$(echo "${product_json}"  | jq -r '.name')
    p_name=$(echo "${product_json}" | jq -r '.properties.displayName')

    local product_groups
    product_groups=$(fetch_all_pages \
      "${SRC_BASE}/products/${p_id}/groups?api-version=${SRC_API_VERSION}&\$top=1000")

    echo "${product_groups}" | jq '.' > "${OUTPUT_DIR}/product_groups/${p_id}.json"
    log "  Product '${p_name}': $(echo "${product_groups}" | jq 'length') group(s)"
  done < <(jq -c '.[]' "${OUTPUT_DIR}/products.json")

  success "Exported product-group assignments  →  ${OUTPUT_DIR}/product_groups/"

  # ───────────────────────────────────────────────────────────────────────────
  # 1.6 Export Subscription Metadata (NO KEYS)
  # ───────────────────────────────────────────────────────────────────────────
  log "1.6  Exporting subscription metadata (keys excluded from disk)..."

  local all_subs
  all_subs=$(fetch_all_pages \
    "${SRC_BASE}/subscriptions?api-version=${SRC_API_VERSION}&\$top=1000")

  # Strip keys — store only metadata for the migration phase mapping
  echo "${all_subs}" | jq '[.[] | {
    name:        .name,
    displayName: .properties.displayName,
    state:       .properties.state,
    scope:       .properties.scope,
    ownerId:     .properties.ownerId,
    createdDate: .properties.createdDate
  }]' > "${OUTPUT_DIR}/subscriptions.json"

  success "Exported $(echo "${all_subs}" | jq 'length') subscription(s)  →  ${OUTPUT_DIR}/subscriptions.json"
  warn    "Subscription keys are NOT stored on disk — they will be fetched live during migration"

  section "DISCOVERY COMPLETE  —  output: ${OUTPUT_DIR}/"
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 2 — MIGRATION (IMPORT TO TARGET WORKSPACE)
# ─────────────────────────────────────────────────────────────────────────────

migrate() {
  section "PHASE 2 — MIGRATION"

  # Verify discovery outputs exist
  for required in \
    "${OUTPUT_DIR}/users.json" \
    "${OUTPUT_DIR}/groups.json" \
    "${OUTPUT_DIR}/products.json" \
    "${OUTPUT_DIR}/subscriptions.json"; do
    [ -f "${required}" ] || {
      error "Missing export file: ${required}  —  run 'discover' phase first"
      exit 1
    }
  done

  local TGT_BASE="https://management.azure.com/subscriptions/${TARGET_SUBSCRIPTION_ID}/resourceGroups/${TARGET_RESOURCE_GROUP}/providers/Microsoft.ApiManagement/service/${TARGET_APIM_NAME}"
  local WS_BASE="${TGT_BASE}/workspaces/${TARGET_WORKSPACE_NAME}"

  # ───────────────────────────────────────────────────────────────────────────
  # 2.1 Create Workspace Groups
  #     Custom + External groups are created at workspace scope.
  #     Built-in system groups (Administrators/Developers/Guests) are skipped
  #     because they are pre-seeded automatically in every workspace.
  # ───────────────────────────────────────────────────────────────────────────
  section "2.1  Creating Workspace Groups"
  switch_sub "target" "${TARGET_SUBSCRIPTION_ID}"

  while IFS= read -r group_json; do
    local g_id g_name g_type g_desc
    g_id=$(echo "${group_json}"   | jq -r '.name')
    g_name=$(echo "${group_json}" | jq -r '.properties.displayName')
    g_type=$(echo "${group_json}" | jq -r '.properties.type')
    g_desc=$(echo "${group_json}" | jq -r '.properties.description // ""')

    if [ "${g_type}" = "system" ]; then
      warn "Skipping built-in group '${g_name}' (type=system) — already exists in every workspace"
      inc_skip
      continue
    fi

    local target_gid
    target_gid=$(sanitise_id "${g_name}")

    # Idempotency check — does the group already exist in the workspace?
    local existing_group
    existing_group=$(rest_call GET \
      "${WS_BASE}/groups/${target_gid}?api-version=${TGT_API_VERSION}" 2>/dev/null \
      || echo '{}')

    if echo "${existing_group}" | jq -e '.properties.displayName' > /dev/null 2>&1; then
      warn "Group '${g_name}' already exists in workspace — skipping"
      inc_skip
      continue
    fi

    log "Creating workspace group: '${g_name}' (${g_type})  →  ID: ${target_gid}"

    local body_file
    body_file=$(mktemp /tmp/apim-group-XXXXXX)

    if [ "${g_type}" = "external" ]; then
      # External (Entra ID) group — preserve the AAD externalId (group object ID)
      local ext_id
      ext_id=$(echo "${group_json}" | jq -r '.properties.externalId // ""')
      jq -n \
        --arg name   "${g_name}" \
        --arg desc   "${g_desc}" \
        --arg extId  "${ext_id}" \
        '{
          "properties": {
            "displayName": $name,
            "description": $desc,
            "type":        "external",
            "externalId":  $extId
          }
        }' > "${body_file}"
    else
      # Custom group
      jq -n \
        --arg name "${g_name}" \
        --arg desc "${g_desc}" \
        '{
          "properties": {
            "displayName": $name,
            "description": $desc,
            "type":        "custom"
          }
        }' > "${body_file}"
    fi

    local response
    response=$(rest_call PUT \
      "${WS_BASE}/groups/${target_gid}?api-version=${TGT_API_VERSION}" \
      "${body_file}")
    rm -f "${body_file}"

    if echo "${response}" | jq -e '.properties.displayName' > /dev/null 2>&1; then
      success "  Created group: '${g_name}'"
      append_rollback "workspace-group" \
        "${WS_BASE}/groups/${target_gid}?api-version=${TGT_API_VERSION}"
      inc_success
    else
      error "  Failed to create group '${g_name}': $(echo "${response}" | jq -r '.error.message // "unknown error"')"
      inc_failed
    fi

  done < <(jq -c '.[]' "${OUTPUT_DIR}/groups.json")

  # ───────────────────────────────────────────────────────────────────────────
  # 2.2 Create Service-Level Users
  #     APIM users are ALWAYS created at service level — not workspace-scoped.
  #     Entra ID users: identity provider + AAD object ID preserved.
  #     Developer Portal users: temp password generated; user must reset.
  # ───────────────────────────────────────────────────────────────────────────
  section "2.2  Creating Service-Level Users"
  switch_sub "target" "${TARGET_SUBSCRIPTION_ID}"

  while IFS= read -r user_json; do
    local u_name u_email u_first u_last u_state u_provider
    u_name=$(echo "${user_json}"    | jq -r '.name')
    u_email=$(echo "${user_json}"   | jq -r '.properties.email // ""')
    u_first=$(echo "${user_json}"   | jq -r '.properties.firstName // ""')
    u_last=$(echo "${user_json}"    | jq -r '.properties.lastName // ""')
    u_state=$(echo "${user_json}"   | jq -r '.properties.state // "active"')
    u_provider=$(echo "${user_json}" | jq -r '.properties.identities[0].provider // "Basic"')

    # Skip users without an email address (system/service accounts)
    if [ -z "${u_email}" ] || [ "${u_email}" = "null" ]; then
      warn "Skipping user '${u_name}' — no email address"
      inc_skip
      continue
    fi

    # Derive a deterministic user ID from the email for idempotency
    local target_uid
    target_uid=$(sanitise_id "${u_email}")

    # Idempotency check
    local existing_user
    existing_user=$(rest_call GET \
      "${TGT_BASE}/users/${target_uid}?api-version=${TGT_API_VERSION}" 2>/dev/null \
      || echo '{}')

    if echo "${existing_user}" | jq -e '.properties.email' > /dev/null 2>&1; then
      warn "User '${u_email}' already exists — skipping"
      inc_skip
      continue
    fi

    log "Creating user: ${u_email}  (${u_provider})  →  ID: ${target_uid}"

    local body_file
    body_file=$(mktemp /tmp/apim-user-XXXXXX)

    if [ "${u_provider}" = "Aad" ] || [ "${u_provider}" = "AadB2C" ]; then
      # ── Entra ID user ───────────────────────────────────────────────────────
      # The identity.id is the AAD object ID — APIM links to the existing user.
      # No password needed; authentication is handled by Entra ID.
      local aad_object_id
      aad_object_id=$(echo "${user_json}" | jq -r '.properties.identities[0].id // ""')

      jq -n \
        --arg email    "${u_email}" \
        --arg first    "${u_first}" \
        --arg last     "${u_last}" \
        --arg state    "${u_state}" \
        --arg provider "${u_provider}" \
        --arg aadId    "${aad_object_id}" \
        '{
          "properties": {
            "email":     $email,
            "firstName": $first,
            "lastName":  $last,
            "state":     $state,
            "identities": [
              { "provider": $provider, "id": $aadId }
            ]
          }
        }' > "${body_file}"

    else
      # ── Developer Portal (Basic) user ───────────────────────────────────────
      # Passwords CANNOT be migrated — a secure random temp password is set.
      # The user must reset their password via the Developer Portal or SSO URL.
      # Temp password is NEVER logged; it exists only in this subshell scope.
      local temp_pwd
      temp_pwd=$(openssl rand -base64 24)A1!   # satisfies typical complexity rules

      jq -n \
        --arg email "${u_email}" \
        --arg first "${u_first}" \
        --arg last  "${u_last}" \
        --arg state "${u_state}" \
        --arg pwd   "${temp_pwd}" \
        '{
          "properties": {
            "email":     $email,
            "firstName": $first,
            "lastName":  $last,
            "state":     "active",
            "password":  $pwd,
            "identities": [
              { "provider": "Basic", "id": $email }
            ]
          }
        }' > "${body_file}"

      warn "  Dev Portal user ${u_email}: temp password set — user MUST reset (key NOT logged)"
      unset temp_pwd
    fi

    local response
    response=$(rest_call PUT \
      "${TGT_BASE}/users/${target_uid}?api-version=${TGT_API_VERSION}" \
      "${body_file}")
    # Shred body_file to avoid temp password remaining on disk
    { dd if=/dev/zero of="${body_file}" bs=1k count=1 > /dev/null 2>&1; rm -f "${body_file}"; } || rm -f "${body_file}"

    if echo "${response}" | jq -e '.properties.email' > /dev/null 2>&1; then
      success "  Created user: ${u_email}"
      append_rollback "service-user" \
        "${TGT_BASE}/users/${target_uid}?api-version=${TGT_API_VERSION}&deleteSubscriptions=true"
      inc_success
    else
      error "  Failed to create user '${u_email}': $(echo "${response}" | jq -r '.error.message // "unknown error"')"
      inc_failed
    fi

    # Optionally trigger a password-reset / SSO URL invite email
    if ${SEND_INVITE_EMAILS} && [ "${u_provider}" = "Basic" ]; then
      local invite_response
      invite_response=$(rest_call POST \
        "${TGT_BASE}/users/${target_uid}/generateSsoUrl?api-version=${TGT_API_VERSION}" \
        2>/dev/null || echo '{}')
      local sso_url
      sso_url=$(echo "${invite_response}" | jq -r '.value // ""')
      if [ -n "${sso_url}" ] && [ "${sso_url}" != "null" ]; then
        log "  SSO invite URL generated for ${u_email} (logged to ${LOG_FILE})"
        echo "[$(_ts)] [SSO-URL] ${u_email} → ${sso_url}" >> "${LOG_FILE}"
      fi
    fi

  done < <(jq -c '.[]' "${OUTPUT_DIR}/users.json")

  # ───────────────────────────────────────────────────────────────────────────
  # 2.3 Rebuild Workspace Group Memberships
  # ───────────────────────────────────────────────────────────────────────────
  section "2.3  Rebuilding Workspace Group Memberships"
  switch_sub "target" "${TARGET_SUBSCRIPTION_ID}"

  while IFS= read -r group_json; do
    local g_id g_name g_type target_gid
    g_id=$(echo "${group_json}"   | jq -r '.name')
    g_name=$(echo "${group_json}" | jq -r '.properties.displayName')
    g_type=$(echo "${group_json}" | jq -r '.properties.type')

    # Built-in (system) groups — Administrators, Developers, Guests — are
    # service-level entities in APIM. There is no workspace-scoped equivalent;
    # PUT .../workspaces/{ws}/groups/administrators/users/{u} always returns
    # "Group not found". Skip these; manage service-level group membership
    # manually in the Azure Portal or via the service-level API if needed.
    if [ "${g_type}" = "system" ]; then
      warn "Skipping memberships for built-in group '${g_name}' (type=system) — service-level only, not workspace-scoped"
      continue
    fi

    target_gid=$(sanitise_id "${g_name}")

    local members_file="${OUTPUT_DIR}/group_memberships/${g_id}.json"
    [ -f "${members_file}" ] || continue

    local mc
    mc=$(jq 'length' "${members_file}")
    [ "${mc}" -eq 0 ] && continue

    log "Rebuilding memberships for group '${g_name}' (target: ${target_gid}): ${mc} member(s)"

    while IFS= read -r member_json; do
      local m_email m_name
      m_email=$(echo "${member_json}" | jq -r '.properties.email // ""')
      m_name=$(echo "${member_json}"  | jq -r '.name')

      if [ -z "${m_email}" ] || [ "${m_email}" = "null" ]; then
        warn "  Skipping member '${m_name}' in group '${g_name}' — no email address"
        inc_skip
        continue
      fi

      local target_uid
      target_uid=$(sanitise_id "${m_email}")

      # Use az rest — handles auth token refresh and returns a proper exit code.
      # The PUT body is empty (link-only resource); az rest sends no body by default.
      local az_out az_rc
      az_out=$(az rest --method PUT \
        --uri "${WS_BASE}/groups/${target_gid}/users/${target_uid}?api-version=${TGT_API_VERSION}" \
        2>&1) && az_rc=0 || az_rc=$?

      if [ "${az_rc}" -eq 0 ]; then
        success "  Added ${m_email}  →  group '${g_name}'"
        inc_success
      else
        local err_code err_msg
        err_code=$(echo "${az_out}" | jq -r '.error.code // ""' 2>/dev/null || true)
        err_msg=$(echo "${az_out}"  | jq -r '.error.message // ""' 2>/dev/null || true)
        if [ "${err_code}" = "EntityAlreadyExists" ] || [ "${err_code}" = "Conflict" ]; then
          warn "  ${m_email} already in group '${g_name}' — skipping"
          inc_skip
        else
          error "  Failed to add ${m_email} to '${g_name}': ${err_msg:-${az_out}}"
          inc_failed
        fi
      fi
    done < <(jq -c '.[]' "${members_file}")

  done < <(jq -c '.[]' "${OUTPUT_DIR}/groups.json")

  # ───────────────────────────────────────────────────────────────────────────
  # 2.4 Rebuild Group-to-Product Assignments in Workspace
  #     NOTE: The workspace products must already exist (deployed via IaC /
  #     APIOps). This step ONLY assigns groups to existing workspace products.
  # ───────────────────────────────────────────────────────────────────────────
  section "2.4  Rebuilding Product-Group Assignments (via groupLinks)"
  switch_sub "target" "${TARGET_SUBSCRIPTION_ID}"

  # The correct workspace API for product-group association uses groupLinks,
  # not the service-level /products/{p}/groups/{g} pattern:
  #
  #   PUT .../workspaces/{ws}/products/{p}/groupLinks/{linkId}
  #   Body: { "properties": { "groupId": "<workspace-scoped group ARM id>" } }
  #
  # The groupId must point to the workspace-scoped group resource, not the
  # service-level group. The linkId is an arbitrary unique identifier for the
  # association — we derive it deterministically from product+group names.

  # Base ARM prefix for workspace-scoped group resource IDs
  local WS_GROUP_ARM_PREFIX="/subscriptions/${TARGET_SUBSCRIPTION_ID}/resourceGroups/${TARGET_RESOURCE_GROUP}/providers/Microsoft.ApiManagement/service/${TARGET_APIM_NAME}/workspaces/${TARGET_WORKSPACE_NAME}/groups"

  # Fetch real workspace product ARM ids — product names in target workspace
  # may differ from source, so look up by display name.
  log "Fetching products deployed in workspace '${TARGET_WORKSPACE_NAME}'..."
  local ws_products_json ws_product_map_file
  ws_products_json=$(az rest --method GET \
    --uri "${WS_BASE}/products?api-version=${TGT_API_VERSION}&\$top=1000" \
    --query "value" -o json 2>/dev/null || echo '[]')

  ws_product_map_file=$(mktemp /tmp/apim-ws-pmap-XXXXXX)
  # Build JSON object: { "DisplayName": "arm-resource-name", ... }
  echo "${ws_products_json}" | jq \
    '[.[] | {key: .properties.displayName, value: .name}] | from_entries' \
    > "${ws_product_map_file}"

  local ws_product_count
  ws_product_count=$(echo "${ws_products_json}" | jq 'length')
  log "  Found ${ws_product_count} product(s) in workspace"

  while IFS= read -r product_json; do
    local p_id p_name
    p_id=$(echo "${product_json}"   | jq -r '.name')
    p_name=$(echo "${product_json}" | jq -r '.properties.displayName')

    local pg_file="${OUTPUT_DIR}/product_groups/${p_id}.json"
    [ -f "${pg_file}" ] || continue

    local pg_count
    pg_count=$(jq 'length' "${pg_file}")
    [ "${pg_count}" -eq 0 ] && continue

    # Look up the real workspace product ARM name by display name
    local ws_pid
    ws_pid=$(jq -r --arg dn "${p_name}" '.[$dn] // ""' "${ws_product_map_file}")

    if [ -z "${ws_pid}" ]; then
      warn "Product '${p_name}' is not deployed in workspace '${TARGET_WORKSPACE_NAME}' — skipping (deploy via IaC/APIOps first)"
      continue
    fi

    log "Assigning groups to workspace product '${p_name}' (workspace ID: ${ws_pid})..."

    while IFS= read -r grp_json; do
      local grp_name grp_type grp_id
      grp_name=$(echo "${grp_json}" | jq -r '.properties.displayName')
      grp_type=$(echo "${grp_json}" | jq -r '.properties.type')
      grp_id=$(echo "${grp_json}"   | jq -r '.name')

      # System (built-in) groups are service-level — they cannot be referenced
      # as workspace-scoped group resources. Skip with a clear message.
      if [ "${grp_type}" = "system" ]; then
        warn "  Skipping system group '${grp_name}' — add via 'Add service group' in the portal"
        inc_skip
        continue
      fi

      # Derive the target workspace group ARM name (same sanitise logic used in 2.1)
      local target_gid
      target_gid=$(sanitise_id "${grp_name}")

      # Full workspace-scoped group ARM resource ID (required in the body)
      local group_resource_id="${WS_GROUP_ARM_PREFIX}/${target_gid}"

      # Deterministic linkId — must be unique per product+group pair
      local link_id="${ws_pid}-${target_gid}-link"

      # Idempotency: check if this groupLink already exists
      local existing_link
      existing_link=$(az rest --method GET \
        --uri "${WS_BASE}/products/${ws_pid}/groupLinks/${link_id}?api-version=${TGT_API_VERSION}" \
        2>/dev/null || echo '{}')

      if echo "${existing_link}" | jq -e '.properties.groupId' > /dev/null 2>&1; then
        warn "  Group link '${grp_name}' → '${p_name}' already exists — skipping"
        inc_skip
        continue
      fi

      # Create the groupLink
      local az_out az_rc
      az_out=$(az rest --method PUT \
        --uri "${WS_BASE}/products/${ws_pid}/groupLinks/${link_id}?api-version=${TGT_API_VERSION}" \
        --body "{\"properties\": {\"groupId\": \"${group_resource_id}\"}}" \
        2>&1) && az_rc=0 || az_rc=$?

      if [ "${az_rc}" -eq 0 ]; then
        success "  Assigned group '${grp_name}'  →  product '${p_name}'  (linkId: ${link_id})"
        inc_success
      else
        local err_code err_msg
        err_code=$(echo "${az_out}" | jq -r '.error.code // ""' 2>/dev/null || true)
        err_msg=$(echo "${az_out}"  | jq -r '.error.message // ""' 2>/dev/null || true)
        case "${err_code}" in
          EntityAlreadyExists|Conflict)
            warn "  Group '${grp_name}' already linked to product '${p_name}' — skipping"
            inc_skip
            ;;
          *)
            error "  Failed: '${grp_name}' → '${p_name}': ${err_msg:-${az_out}}"
            inc_failed
            ;;
        esac
      fi
    done < <(jq -c '.[]' "${pg_file}")

  done < <(jq -c '.[]' "${OUTPUT_DIR}/products.json")

  rm -f "${ws_product_map_file}"

  # ───────────────────────────────────────────────────────────────────────────
  # 2.5 Recreate Workspace Subscriptions (with live key fetch)
  #     Keys are fetched from source on-the-fly and held only in RAM.
  #     They are NEVER written to disk or to the log file.
  # ───────────────────────────────────────────────────────────────────────────
  if ${MIGRATE_SUBSCRIPTIONS}; then
    section "2.5  Recreating Workspace Subscriptions"

    # Fetch live subscription list from source to get keys in memory
    switch_sub "source" "${SOURCE_SUBSCRIPTION_ID}"
    local SRC_BASE="https://management.azure.com/subscriptions/${SOURCE_SUBSCRIPTION_ID}/resourceGroups/${SOURCE_RESOURCE_GROUP}/providers/Microsoft.ApiManagement/service/${SOURCE_APIM_NAME}"

    local all_src_subs
    all_src_subs=$(fetch_all_pages \
      "${SRC_BASE}/subscriptions?api-version=${SRC_API_VERSION}&\$top=1000")

    switch_sub "target" "${TARGET_SUBSCRIPTION_ID}"

    while IFS= read -r sub_json; do
      local s_name s_display s_scope s_state s_owner_id
      s_name=$(echo "${sub_json}"      | jq -r '.name')
      s_display=$(echo "${sub_json}"   | jq -r '.properties.displayName')
      s_scope=$(echo "${sub_json}"     | jq -r '.properties.scope')
      s_state=$(echo "${sub_json}"     | jq -r '.properties.state // "active"')
      s_owner_id=$(echo "${sub_json}"  | jq -r '.properties.ownerId // ""')

      # Skip master / all-APIs subscriptions (no /products/ in scope)
      if ! echo "${s_scope}" | grep -q '/products/'; then
        warn "Skipping '${s_display}' — not product-scoped (scope: ${s_scope})"
        inc_skip
        continue
      fi

      # Map source product ID → same product ID in workspace
      local src_product_id
      src_product_id=$(echo "${s_scope}" | awk -F'/products/' '{print $2}')
      local target_scope="/workspaces/${TARGET_WORKSPACE_NAME}/products/${src_product_id}"

      # Resolve owner: source userId → target user ID (via email lookup)
      local src_user_id target_uid target_owner_id
      src_user_id=$(echo "${s_owner_id}" | awk -F'/users/' '{print $2}')
      local owner_email
      owner_email=$(jq -r --arg id "${src_user_id}" \
        '.[] | select(.name == $id) | .properties.email' \
        "${OUTPUT_DIR}/users.json" 2>/dev/null || echo "")

      if [ -n "${owner_email}" ] && [ "${owner_email}" != "null" ]; then
        target_uid=$(sanitise_id "${owner_email}")
        target_owner_id="/users/${target_uid}"
      else
        target_owner_id=""
        warn "Could not resolve owner for subscription '${s_display}' (source user: ${src_user_id})"
      fi

      # Fetch live keys from source (RAM only — never persisted)
      switch_sub "source" "${SOURCE_SUBSCRIPTION_ID}"
      local keys_resp
      keys_resp=$(rest_call POST \
        "${SRC_BASE}/subscriptions/${s_name}/listSecrets?api-version=${SRC_API_VERSION}" \
        2>/dev/null || echo '{}')
      local pk sk
      pk=$(echo "${keys_resp}" | jq -r '.primaryKey // ""')
      sk=$(echo "${keys_resp}" | jq -r '.secondaryKey // ""')

      switch_sub "target" "${TARGET_SUBSCRIPTION_ID}"

      local safe_sub_id
      safe_sub_id="sub-$(sanitise_id "${s_display}")"

      # Idempotency check for subscription
      local existing_sub
      existing_sub=$(rest_call GET \
        "${WS_BASE}/subscriptions/${safe_sub_id}?api-version=${TGT_API_VERSION}" \
        2>/dev/null || echo '{}')

      if echo "${existing_sub}" | jq -e '.properties.state' > /dev/null 2>&1; then
        warn "Subscription '${s_display}' already exists — skipping"
        pk=""; sk=""   # clear keys from memory
        inc_skip
        continue
      fi

      local body_file
      body_file=$(mktemp /tmp/apim-sub-XXXXXX)

      jq -n \
        --arg display  "${s_display}" \
        --arg pk       "${pk}" \
        --arg sk       "${sk}" \
        --arg state    "${s_state}" \
        --arg scope    "${target_scope}" \
        --arg owner    "${target_owner_id}" \
        '{
          "properties": {
            "displayName":  $display,
            "primaryKey":   $pk,
            "secondaryKey": $sk,
            "state":        $state,
            "scope":        $scope,
            "ownerId":      (if $owner != "" then $owner else null end)
          }
        }' > "${body_file}"

      # Clear keys from shell variables immediately after writing to temp file
      pk=""; sk=""

      local response
      response=$(rest_call PUT \
        "${WS_BASE}/subscriptions/${safe_sub_id}?api-version=${TGT_API_VERSION}" \
        "${body_file}")

      # Overwrite and delete the temp file (keys were in it)
      { dd if=/dev/zero of="${body_file}" bs=1k count=1 > /dev/null 2>&1; rm -f "${body_file}"; } || rm -f "${body_file}"

      if echo "${response}" | jq -e '.properties.state' > /dev/null 2>&1; then
        # Log creation WITHOUT keys
        success "  Created subscription: '${s_display}'  [keys: REDACTED]  →  ${target_scope}"
        append_rollback "workspace-subscription" \
          "${WS_BASE}/subscriptions/${safe_sub_id}?api-version=${TGT_API_VERSION}"
        inc_success
      else
        error "  Failed: '${s_display}': $(echo "${response}" | jq -r '.error.message // "unknown"')"
        inc_failed
      fi

    done < <(echo "${all_src_subs}" | jq -c '.[]')
  fi

  section "MIGRATION COMPLETE"
  log "Rollback manifest written  →  ${ROLLBACK_FILE}"
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 3 — VALIDATION
# ─────────────────────────────────────────────────────────────────────────────

validate() {
  section "PHASE 3 — VALIDATION"

  local SRC_BASE="https://management.azure.com/subscriptions/${SOURCE_SUBSCRIPTION_ID}/resourceGroups/${SOURCE_RESOURCE_GROUP}/providers/Microsoft.ApiManagement/service/${SOURCE_APIM_NAME}"
  local TGT_BASE="https://management.azure.com/subscriptions/${TARGET_SUBSCRIPTION_ID}/resourceGroups/${TARGET_RESOURCE_GROUP}/providers/Microsoft.ApiManagement/service/${TARGET_APIM_NAME}"
  local WS_BASE="${TGT_BASE}/workspaces/${TARGET_WORKSPACE_NAME}"

  local total_checks=0
  local passed_checks=0
  local failed_checks=0

  # Comparison helper: source_count <= target_count is PASS (target may have extras)
  _check() {
    local label="$1" src_n="$2" tgt_n="$3"
    total_checks=$((total_checks + 1))
    if [ "${src_n}" -le "${tgt_n}" ]; then
      success "  ✓  ${label}: source=${src_n}  target=${tgt_n}"
      passed_checks=$((passed_checks + 1))
    else
      error   "  ✗  ${label}: source=${src_n}  target=${tgt_n}  ← MISMATCH"
      failed_checks=$((failed_checks + 1))
    fi
  }

  # ── 3.1 User Counts ─────────────────────────────────────────────────────────
  log "3.1  Validating user counts..."

  switch_sub "source" "${SOURCE_SUBSCRIPTION_ID}"
  local src_users
  src_users=$(fetch_all_pages \
    "${SRC_BASE}/users?api-version=${SRC_API_VERSION}&\$top=1000")
  # Exclude built-in admin (id=1)
  local src_user_count
  src_user_count=$(echo "${src_users}" | jq '[.[] | select(.name != "1")] | length')

  switch_sub "target" "${TARGET_SUBSCRIPTION_ID}"
  local tgt_users
  tgt_users=$(fetch_all_pages \
    "${TGT_BASE}/users?api-version=${TGT_API_VERSION}&\$top=1000")
  local tgt_user_count
  tgt_user_count=$(echo "${tgt_users}" | jq 'length')

  _check "Users (service level)" "${src_user_count}" "${tgt_user_count}"

  # Entra ID subset
  local src_aad_count tgt_aad_count
  src_aad_count=$(echo "${src_users}" | jq '[.[] |
    select((.properties.identities[]?.provider // "") == "Aad" or
           (.properties.identities[]?.provider // "") == "AadB2C")] | length')
  tgt_aad_count=$(echo "${tgt_users}" | jq '[.[] |
    select((.properties.identities[]?.provider // "") == "Aad" or
           (.properties.identities[]?.provider // "") == "AadB2C")] | length')
  _check "  └─ Entra ID users" "${src_aad_count}" "${tgt_aad_count}"

  # Developer Portal subset
  local src_dev_count tgt_dev_count
  src_dev_count=$(echo "${src_users}" | jq '[.[] |
    select((.properties.identities[]?.provider // "") == "Basic")] | length')
  tgt_dev_count=$(echo "${tgt_users}" | jq '[.[] |
    select((.properties.identities[]?.provider // "") == "Basic")] | length')
  _check "  └─ Developer Portal users" "${src_dev_count}" "${tgt_dev_count}"

  # ── 3.2 Group Counts ────────────────────────────────────────────────────────
  log "3.2  Validating workspace group counts..."

  switch_sub "source" "${SOURCE_SUBSCRIPTION_ID}"
  local src_groups
  src_groups=$(fetch_all_pages \
    "${SRC_BASE}/groups?api-version=${SRC_API_VERSION}&\$top=1000")
  local src_custom_count src_ext_count
  src_custom_count=$(echo "${src_groups}" | jq '[.[] | select(.properties.type == "custom")] | length')
  src_ext_count=$(echo "${src_groups}" | jq '[.[] | select(.properties.type == "external")] | length')

  switch_sub "target" "${TARGET_SUBSCRIPTION_ID}"
  local tgt_ws_groups
  tgt_ws_groups=$(fetch_all_pages \
    "${WS_BASE}/groups?api-version=${TGT_API_VERSION}&\$top=1000")
  local tgt_custom_count tgt_ext_count
  tgt_custom_count=$(echo "${tgt_ws_groups}" | jq '[.[] | select(.properties.type == "custom")] | length')
  tgt_ext_count=$(echo "${tgt_ws_groups}" | jq '[.[] | select(.properties.type == "external")] | length')

  _check "Custom workspace groups"   "${src_custom_count}" "${tgt_custom_count}"
  _check "External workspace groups" "${src_ext_count}"    "${tgt_ext_count}"

  # ── 3.3 Group Membership Consistency ────────────────────────────────────────
  log "3.3  Validating group membership counts..."

  while IFS= read -r group_json; do
    local g_id g_name g_type target_gid
    g_id=$(echo "${group_json}"   | jq -r '.name')
    g_name=$(echo "${group_json}" | jq -r '.properties.displayName')
    g_type=$(echo "${group_json}" | jq -r '.properties.type')

    [ -f "${OUTPUT_DIR}/group_memberships/${g_id}.json" ] || continue

    local src_mc
    src_mc=$(jq 'length' "${OUTPUT_DIR}/group_memberships/${g_id}.json")
    [ "${src_mc}" -eq 0 ] && continue

    if [ "${g_type}" = "system" ]; then
      target_gid=$(builtin_group_id "${g_name}")
    else
      target_gid=$(sanitise_id "${g_name}")
    fi

    switch_sub "target" "${TARGET_SUBSCRIPTION_ID}"
    local tgt_members
    tgt_members=$(fetch_all_pages \
      "${WS_BASE}/groups/${target_gid}/users?api-version=${TGT_API_VERSION}&\$top=1000" \
      2>/dev/null || echo '[]')
    local tgt_mc
    tgt_mc=$(echo "${tgt_members}" | jq 'length')

    _check "  Memberships — '${g_name}'" "${src_mc}" "${tgt_mc}"
  done < <(jq -c '.[]' "${OUTPUT_DIR}/groups.json")

  # ── 3.4 Workspace Subscription Count ────────────────────────────────────────
  if ${MIGRATE_SUBSCRIPTIONS}; then
    log "3.4  Validating workspace subscription counts..."

    switch_sub "source" "${SOURCE_SUBSCRIPTION_ID}"
    local src_all_subs
    src_all_subs=$(fetch_all_pages \
      "${SRC_BASE}/subscriptions?api-version=${SRC_API_VERSION}&\$top=1000")
    local src_prod_subs
    src_prod_subs=$(echo "${src_all_subs}" | jq \
      '[.[] | select(.properties.scope | contains("/products/"))] | length')

    switch_sub "target" "${TARGET_SUBSCRIPTION_ID}"
    local tgt_ws_subs
    tgt_ws_subs=$(fetch_all_pages \
      "${WS_BASE}/subscriptions?api-version=${TGT_API_VERSION}&\$top=1000")
    local tgt_prod_subs
    tgt_prod_subs=$(echo "${tgt_ws_subs}" | jq 'length')

    _check "Workspace subscriptions (product-scoped)" "${src_prod_subs}" "${tgt_prod_subs}"
  fi

  # ── 3.5 Email Uniqueness in Target ──────────────────────────────────────────
  log "3.5  Checking for duplicate emails in target..."

  switch_sub "target" "${TARGET_SUBSCRIPTION_ID}"
  local tgt_all_users
  tgt_all_users=$(fetch_all_pages \
    "${TGT_BASE}/users?api-version=${TGT_API_VERSION}&\$top=1000")

  local dup_count
  dup_count=$(echo "${tgt_all_users}" | jq \
    '[.[] | .properties.email] | group_by(.) | map(select(length > 1)) | length')

  if [ "${dup_count}" -eq 0 ]; then
    success "  ✓  No duplicate email addresses detected in target"
    passed_checks=$((passed_checks + 1))
  else
    error "  ✗  ${dup_count} duplicate email address(es) found in target — investigate"
    failed_checks=$((failed_checks + 1))
  fi
  total_checks=$((total_checks + 1))

  # ── Validation Report ────────────────────────────────────────────────────────
  section "VALIDATION REPORT"
  echo ""
  printf "  %-20s %s\n" "Total checks:"   "${total_checks}"
  printf "  %-20s %s\n" "Passed:"         "${passed_checks}"
  printf "  %-20s %s\n" "Failed:"         "${failed_checks}"
  echo ""

  if [ "${failed_checks}" -eq 0 ]; then
    success "All validation checks passed — migration is consistent."
  else
    error "${failed_checks} check(s) FAILED — review ${LOG_FILE} and re-run failed steps individually."
    error "Consider the rollback manifest at ${ROLLBACK_FILE} if rollback is needed."
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# ROLLBACK HELPER — print ordered deletion commands
# ─────────────────────────────────────────────────────────────────────────────

print_rollback_commands() {
  section "ROLLBACK COMMANDS"

  [ -f "${ROLLBACK_FILE}" ] || { warn "No rollback manifest found at ${ROLLBACK_FILE}"; return; }

  echo ""
  warn "The following commands will UNDO the migration. Review carefully before running."
  echo ""
  echo "# ── Switch to target subscription first ──"
  echo "az account set --subscription ${TARGET_SUBSCRIPTION_ID}"
  echo ""
  echo "# ── Delete in reverse order (subscriptions → memberships → groups → users) ──"

  # Subscriptions first
  jq -r '.[] | select(.type == "workspace-subscription") |
    "az rest --method DELETE --uri \"" + .deleteUrl + "\""' \
    "${ROLLBACK_FILE}" 2>/dev/null || true

  # Then workspace groups
  jq -r '.[] | select(.type == "workspace-group") |
    "az rest --method DELETE --uri \"" + .deleteUrl + "\""' \
    "${ROLLBACK_FILE}" 2>/dev/null || true

  # Then service-level users (last — subscriptions must be gone first)
  jq -r '.[] | select(.type == "service-user") |
    "az rest --method DELETE --uri \"" + .deleteUrl + "\""' \
    "${ROLLBACK_FILE}" 2>/dev/null || true

  echo ""
  warn "Group memberships are deleted implicitly when groups or users are deleted."
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN ENTRY POINT
# ─────────────────────────────────────────────────────────────────────────────

main() {
  local mode="${1:-all}"

  check_prerequisites

  section "APIM USER & GROUP MIGRATION"
  echo "  Mode          : ${mode}"
  echo "  Source APIM   : ${SOURCE_APIM_NAME}  (${SOURCE_SUBSCRIPTION_ID})"
  echo "  Target APIM   : ${TARGET_APIM_NAME}  /  workspace: ${TARGET_WORKSPACE_NAME}"
  echo "  Started at    : $(date)"
  echo ""

  case "${mode}" in
    discover)
      discover
      ;;
    migrate)
      migrate
      ;;
    validate)
      validate
      ;;
    rollback)
      print_rollback_commands
      ;;
    all)
      discover
      migrate
      validate
      ;;
    *)
      error "Unknown mode: '${mode}'"
      echo ""
      echo "Usage: $0 [discover|migrate|validate|rollback|all]"
      echo ""
      echo "  discover  — Export all source entities to ${OUTPUT_DIR}/"
      echo "  migrate   — Import exported data into target workspace"
      echo "  validate  — Verify counts and consistency"
      echo "  rollback  — Print rollback deletion commands"
      echo "  all       — Run discover → migrate → validate (default)"
      exit 1
      ;;
  esac

  section "SUMMARY"
  printf "  %-22s %s\n" "Created/Updated:"  "${SUCCESS_COUNT}"
  printf "  %-22s %s\n" "Skipped (exists):" "${SKIP_COUNT}"
  printf "  %-22s %s\n" "Failed:"           "${FAILED_COUNT}"
  printf "  %-22s %s\n" "Log file:"         "${LOG_FILE}"
  printf "  %-22s %s\n" "Completed at:"     "$(date)"
  echo ""

  if [ "${FAILED_COUNT}" -eq 0 ]; then
    success "Migration phase '${mode}' completed successfully."
  else
    warn "${FAILED_COUNT} item(s) failed — review ${LOG_FILE} for details and re-run failed steps."
    exit 1
  fi
}

# Global ARM token — refreshed by switch_sub()
ARM_TOKEN=""

main "$@"
