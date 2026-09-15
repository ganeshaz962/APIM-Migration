#!/bin/bash
#
# ==============================================================================
# step1_subs_key.sh — Export APIM Subscription Keys (Step 1 of Migration)
# ==============================================================================
#
# PURPOSE
#   Exports every subscription (including its primary and secondary keys) from a
#   SOURCE Azure API Management (APIM) instance into a CSV file. This CSV is the
#   input for the follow-up import step (step2_migrate.sh), which recreates the
#   subscriptions inside the TARGET APIM workspace.
#
#   This script performs Step 1 (export) ONLY. It does NOT write anything to the
#   target APIM — the Step 2 import and verification logic is kept commented
#   out at the bottom for reference.
#
# WHAT IT DOES
#   1. Verifies the caller is logged in to Azure (az login).
#   2. Switches the active subscription context to the SOURCE subscription.
#   3. Lists all subscriptions in the source APIM (paginated, 100 per page).
#   4. For each subscription, fetches its display name and secret keys
#      (primary + secondary) via the ARM REST API.
#   5. Writes the results to $EXPORT_FILE as CSV.
#
# CONFIGURATION
#   Edit the SOURCE_* / TARGET_* variables below to point at the correct
#   subscriptions, resource groups, and APIM instances before running.
#
# USAGE
#   ./step1_subs_key.sh
#
# OUTPUT
#   $EXPORT_FILE (subscriptions_export.csv) with columns:
#     Name, DisplayName, PrimaryKey, SecondaryKey
#
# SECURITY NOTE
#   The generated CSV contains plaintext subscription secret keys. Treat it as a
#   secret: do not commit it to source control and delete it once the migration
#   is complete.
# ==============================================================================

# APIM Subscription Keys Migration Script
# Source APIM (Sub A) → Target APIM Workspace (Sub B)

# --- Source APIM configuration (where subscriptions are exported FROM) --------
SOURCE_AZURE_SUB_ID="874a43ac-9423-4b7e-b030-b6023db7be8b"
SOURCE_RG="rg-apim-source-migration"
SOURCE_APIM="apim-source-prem-mig-01"

TARGET_AZURE_SUB_ID="874a43ac-9423-4b7e-b030-b6023db7be8b"
TARGET_RG="rg-apim-dest-migration"
TARGET_APIM="apim-dest-migration-prem"
WORKSPACE_ID="workspace-core-services"

EXPORT_FILE="subscriptions_export.csv"
LOG_FILE="migration_log.txt"

SUCCESS=0
FAILED=0

echo "============================================================"
echo " APIM Subscription Migration (Cross-Subscription)"
echo " Source Sub  : $SOURCE_AZURE_SUB_ID"
echo " Target Sub  : $TARGET_AZURE_SUB_ID"
echo " Workspace   : $WORKSPACE_ID"
echo "============================================================"
echo ""

# Pre-check: Verify az login
echo "🔐 Checking Azure login..."
ACCOUNT=$(az account show --query "user.name" --output tsv 2>&1)
if [ $? -ne 0 ]; then
  echo "❌ Not logged in. Run: az login"
  exit 1
fi
echo "  ✅ Logged in as: $ACCOUNT"
echo ""

# Step 1: Switch to Source Subscription & Export
echo "🔄 Switching to Source subscription: $SOURCE_AZURE_SUB_ID"
az account set --subscription "$SOURCE_AZURE_SUB_ID"
if [ $? -ne 0 ]; then
  echo "❌ Failed to switch to source subscription. Check the subscription ID."
  exit 1
fi
echo "  ✅ Switched to source subscription"
echo ""

echo "📤 Step 1: Exporting subscriptions from Source APIM..."
echo ""

echo "Name,DisplayName,PrimaryKey,SecondaryKey" > $EXPORT_FILE

SUBSCRIPTION_NAMES=""
NEXT_URI="https://management.azure.com/subscriptions/$SOURCE_AZURE_SUB_ID/resourceGroups/$SOURCE_RG/providers/Microsoft.ApiManagement/service/$SOURCE_APIM/subscriptions?api-version=2022-08-01&\$top=100"

while [ -n "$NEXT_URI" ]; do
  RESPONSE=$(az rest --method GET --uri "$NEXT_URI" --output json)
  PAGE_NAMES=$(echo "$RESPONSE" | jq -r '.value[].name')
  SUBSCRIPTION_NAMES=$(printf "%s\n%s" "$SUBSCRIPTION_NAMES" "$PAGE_NAMES")
  NEXT_URI=$(echo "$RESPONSE" | jq -r '.nextLink // empty')
done

SUBSCRIPTION_NAMES=$(echo "$SUBSCRIPTION_NAMES" | grep -v '^$')

TOTAL=$(echo "$SUBSCRIPTION_NAMES" | grep -c .)
echo "  📊 Total subscriptions found: $TOTAL"
echo ""

if [ -z "$SUBSCRIPTION_NAMES" ]; then
  echo "❌ No subscriptions found in source APIM. Check your source config."
  exit 1
fi

for SUB_NAME in $SUBSCRIPTION_NAMES; do

  # Get subscription details
  DETAILS=$(az rest --method GET \
    --uri "https://management.azure.com/subscriptions/$SOURCE_AZURE_SUB_ID/resourceGroups/$SOURCE_RG/providers/Microsoft.ApiManagement/service/$SOURCE_APIM/subscriptions/$SUB_NAME?api-version=2022-08-01")

  DISPLAY_NAME=$(echo $DETAILS | jq -r '.properties.displayName')

  # Get primary + secondary keys
  KEYS=$(az rest --method POST \
    --uri "https://management.azure.com/subscriptions/$SOURCE_AZURE_SUB_ID/resourceGroups/$SOURCE_RG/providers/Microsoft.ApiManagement/service/$SOURCE_APIM/subscriptions/$SUB_NAME/listSecrets?api-version=2022-08-01")

  PRIMARY_KEY=$(echo $KEYS | jq -r '.primaryKey')
  SECONDARY_KEY=$(echo $KEYS | jq -r '.secondaryKey')

  echo "$SUB_NAME,$DISPLAY_NAME,$PRIMARY_KEY,$SECONDARY_KEY" >> $EXPORT_FILE
  echo "  ✅ Exported: $SUB_NAME ($DISPLAY_NAME)"

done

echo ""
echo "📁 Export complete → $EXPORT_FILE"
EXPORTED=$(tail -n +2 $EXPORT_FILE | grep -c .)
echo "  📊 Total subscription keys exported to CSV: $EXPORTED"
echo ""


# Step 3: Verify Migrated Subscriptions
# echo "============================================================"
# echo "🔍 Step 3: Verifying migrated subscriptions in workspace..."
# echo ""

# az rest --method GET \
#   --uri "https://management.azure.com/subscriptions/$TARGET_AZURE_SUB_ID/resourceGroups/$TARGET_RG/providers/Microsoft.ApiManagement/service/$TARGET_APIM/workspaces/$WORKSPACE_ID/subscriptions?api-version=2023-09-01-preview" \
#   --query "value[].{Name:name, DisplayName:properties.displayName, State:properties.state, Scope:properties.scope}" \
#   --output table

# # Cleanup
# rm -f /tmp/sub-body.json

# Summary
# echo ""
# echo "============================================================"
# echo " Migration Summary"
# echo "============================================================"
# echo " ✅ Success : $SUCCESS"
# echo " ❌ Failed  : $FAILED"
# echo " 📁 CSV     : $EXPORT_FILE"
# echo " 📋 Log     : $LOG_FILE"
# echo "============================================================"
# echo ""
# echo "Migration ended: $(date)" >> $LOG_FILE
# echo "Success: $SUCCESS | Failed: $FAILED" >> $LOG_FILE