#!/bin/bash
#
# ==============================================================================
# step2_migrate.sh — Import APIM Subscription Keys (Step 2 of Migration)
# ==============================================================================
#
# PURPOSE
#   Reads the CSV produced by step1_subs_key.sh and applies each subscription's
#   primary/secondary keys to the matching subscription in the TARGET APIM
#   workspace. This makes the target subscriptions use the same keys as the
#   source, so existing API consumers keep working after migration.
#
#   This script performs Step 2 (import/update) ONLY.
#
# WHAT IT DOES
#   1. Switches the active subscription context to the TARGET subscription.
#   2. Reads each row from $EXPORT_FILE (skipping the header).
#   3. For each subscription, sends a PATCH to the ARM REST API setting its
#      primaryKey and secondaryKey.
#   4. Records the outcome per subscription in $RESULTS_FILE and $LOG_FILE.
#   5. Prints a success/failure summary.
#
# PREREQUISITES
#   - step1_subs_key.sh has already been run and produced $EXPORT_FILE.
#   - Azure CLI (az) installed and authenticated: `az login`
#   - jq installed (used for JSON parsing).
#   - The target subscriptions must ALREADY EXIST in the workspace — this script
#     updates keys via PATCH; it does not create new subscriptions.
#   - Caller must have write permission on the target APIM workspace.
#
# CONFIGURATION
#   Edit the SOURCE_* / TARGET_* variables below before running.
#
# USAGE
#   ./step2_migrate.sh
#
# INPUT
#   $EXPORT_FILE (subscriptions_export.csv) with columns:
#     Name, DisplayName, PrimaryKey, SecondaryKey
#
# OUTPUT
#   $RESULTS_FILE (migration_results.csv) — per-subscription status.
#   $LOG_FILE (migration_log.txt)        — appended run log.
#
# SECURITY NOTE
#   The input CSV and the temporary body file (/tmp/sub-body.json) contain
#   plaintext secret keys. Handle them as secrets and remove them afterward.
# ==============================================================================

# --- Source APIM configuration (where the keys were exported FROM) ------------
# Retained for logging/traceability only; this script writes to the target.#!/bin/bash
#
# ==============================================================================
# step2_migrate.sh — Import APIM Subscription Keys (Step 2 of Migration)
# ==============================================================================
#
# PURPOSE
#   Reads the CSV produced by step1_subs_key.sh and applies each subscription's
#   primary/secondary keys to the matching subscription in the TARGET APIM
#   workspace. This makes the target subscriptions use the same keys as the
#   source, so existing API consumers keep working after migration.
#
#   This script performs Step 2 (import/update) ONLY.
#
# WHAT IT DOES
#   1. Switches the active subscription context to the TARGET subscription.
#   2. Reads each row from $EXPORT_FILE (skipping the header).
#   3. For each subscription, sends a PATCH to the ARM REST API setting its
#      primaryKey and secondaryKey.
#   4. Records the outcome per subscription in $RESULTS_FILE and $LOG_FILE.
#   5. Prints a success/failure summary.
#
# PREREQUISITES
#   - step1_subs_key.sh has already been run and produced $EXPORT_FILE.
#   - Azure CLI (az) installed and authenticated: `az login`
#   - jq installed (used for JSON parsing).
#   - The target subscriptions must ALREADY EXIST in the workspace — this script
#     updates keys via PATCH; it does not create new subscriptions.
#   - Caller must have write permission on the target APIM workspace.
#
# CONFIGURATION
#   Edit the SOURCE_* / TARGET_* variables below before running.
#
# USAGE
#   ./step2_migrate.sh
#
# INPUT
#   $EXPORT_FILE (subscriptions_export.csv) with columns:
#     Name, DisplayName, PrimaryKey, SecondaryKey
#
# OUTPUT
#   $RESULTS_FILE (migration_results.csv) — per-subscription status.
#   $LOG_FILE (migration_log.txt)        — appended run log.
#
# SECURITY NOTE
#   The input CSV and the temporary body file (/tmp/sub-body.json) contain
#   plaintext secret keys. Handle them as secrets and remove them afterward.
# ==============================================================================

# --- Source APIM configuration (where the keys were exported FROM) ------------
# Retained for logging/traceability only; this script writes to the target.

SOURCE_AZURE_SUB_ID="874a43ac-9423-4b7e-b030-b6023db7be8b"
SOURCE_RG="rg-apim-source-migration"
SOURCE_APIM="apim-source-prem-mig-01"


TARGET_AZURE_SUB_ID="874a43ac-9423-4b7e-b030-b6023db7be8b"
TARGET_RG="rg-apim-dest-migration"
TARGET_APIM="apim-dest-migration-prem"
WORKSPACE_ID="workspace-core-services"

EXPORT_FILE="subscriptions_export.csv"
LOG_FILE="migration_log.txt"
RESULTS_FILE="migration_results.csv"

SUCCESS=0
FAILED=0

echo "SubscriptionName,Status,Error" > $RESULTS_FILE


# Step 2: Switch to Target Subscription & Migrate
echo "🔄 Switching to Target subscription: $TARGET_AZURE_SUB_ID"
az account set --subscription "$TARGET_AZURE_SUB_ID"
if [ $? -ne 0 ]; then
  echo "❌ Failed to switch to target subscription. Check the subscription ID."
  exit 1
fi
echo "  ✅ Switched to target subscription"
echo ""

echo "📥 Step 2: Migrating subscriptions to workspace: $WORKSPACE_ID..."
echo ""
echo "============================================================" >> $LOG_FILE
echo "Migration started: $(date)" >> $LOG_FILE
echo "Source Sub : $SOURCE_AZURE_SUB_ID" >> $LOG_FILE
echo "Target Sub : $TARGET_AZURE_SUB_ID" >> $LOG_FILE
echo "============================================================" >> $LOG_FILE

tail -n +2 $EXPORT_FILE | while IFS=',' read -r SUB_NAME _DISPLAY_NAME PRIMARY_KEY SECONDARY_KEY; do

  echo "➡️  Updating : $SUB_NAME"

  # Build body with only primary and secondary key
  cat > /tmp/sub-body.json << EOF
{
  "properties": {
    "primaryKey": "$PRIMARY_KEY",
    "secondaryKey": "$SECONDARY_KEY"
  }
}
EOF

  RESPONSE=$(az rest --method PATCH \
    --uri "https://management.azure.com/subscriptions/$TARGET_AZURE_SUB_ID/resourceGroups/$TARGET_RG/providers/Microsoft.ApiManagement/service/$TARGET_APIM/workspaces/$WORKSPACE_ID/subscriptions/$SUB_NAME?api-version=2023-09-01-preview" \
    --headers "If-Match=*" \
    --body @/tmp/sub-body.json 2>&1)

  if echo "$RESPONSE" | jq -e '.properties' > /dev/null 2>&1; then
    echo "  ✅ Updated : $SUB_NAME"
    echo "SUCCESS: $SUB_NAME" >> $LOG_FILE
    echo "$SUB_NAME,SUCCESS," >> $RESULTS_FILE
    SUCCESS=$((SUCCESS + 1))
  else
    ERROR=$(echo "$RESPONSE" | jq -r '.error.message // "Unknown error"' 2>/dev/null)
    echo "  ❌ Failed  : $SUB_NAME"
    echo "  Error     : $ERROR"
    echo "FAILED: $SUB_NAME | $ERROR" >> $LOG_FILE
    echo "$SUB_NAME,FAILED,\"$ERROR\"" >> $RESULTS_FILE
    FAILED=$((FAILED + 1))
  fi

  echo ""

done

echo "============================================================"
echo " Update Summary"
echo "============================================================"
echo " ✅ Success : $SUCCESS"
echo " ❌ Failed  : $FAILED"
echo " 📁 Results : $RESULTS_FILE"
echo "============================================================"