#!/usr/bin/env bash
set -euo pipefail

# -----------------------
# Config
# -----------------------
RESOURCE_GROUP="${RESOURCE_GROUP:-capstone}"
LOCATION="${LOCATION:-eastus}"
STORAGE_ACCOUNT="${STORAGE_ACCOUNT:-capstonefiles$(date +%s | tail -c 6)}"
CONTAINER_NAME="${CONTAINER_NAME:-publicfiles}"
SKU="${SKU:-Standard_LRS}"
KIND="${KIND:-StorageV2}"
LOGFILE="${LOGFILE:-deploy_log.txt}"

timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

echo "$(timestamp) | Starting deployment" | tee -a "$LOGFILE"
echo "$(timestamp) | Using resource group: $RESOURCE_GROUP" | tee -a "$LOGFILE"

# Ensure resource group exists
if ! az group show -n "$RESOURCE_GROUP" &>/dev/null; then
  echo "$(timestamp) | Resource group $RESOURCE_GROUP not found. Exiting." | tee -a "$LOGFILE"
  exit 1
fi

# Create storage account with public access allowed
echo "$(timestamp) | Creating storage account: $STORAGE_ACCOUNT" | tee -a "$LOGFILE"
az storage account create \
  --name "$STORAGE_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --sku "$SKU" \
  --kind "$KIND" \
  --https-only \
  --allow-blob-public-access true \
  --output none

echo "$(timestamp) | Retrieving storage account key" | tee -a "$LOGFILE"
STORAGE_KEY=$(az storage account keys list \
  --account-name "$STORAGE_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --query '[0].value' -o tsv)

if [[ -z "$STORAGE_KEY" ]]; then
  echo "$(timestamp) | Failed to get storage key" | tee -a "$LOGFILE"
  exit 1
fi

# Create container with blob-level public access
echo "$(timestamp) | Creating container: $CONTAINER_NAME (public blob access)" | tee -a "$LOGFILE"
az storage container create \
  --name "$CONTAINER_NAME" \
  --account-name "$STORAGE_ACCOUNT" \
  --account-key "$STORAGE_KEY" \
  --public-access blob \
  --output none

# Save state for CLI reuse
cat > .cloudfiles_state <<EOF
STORAGE_ACCOUNT=$STORAGE_ACCOUNT
CONTAINER_NAME=$CONTAINER_NAME
RESOURCE_GROUP=$RESOURCE_GROUP
STORAGE_KEY=$STORAGE_KEY
LOCATION=$LOCATION
EOF

echo "$(timestamp) | Deployment finished. State saved to .cloudfiles_state" | tee -a "$LOGFILE"
echo "Public container URL: https://$STORAGE_ACCOUNT.blob.core.windows.net/$CONTAINER_NAME/" | tee -a "$LOGFILE"
