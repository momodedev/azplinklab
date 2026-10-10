#!/usr/bin/env bash
set -euo pipefail

SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-95642268-5116-484d-9b88-7dfce8c20ce4}"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-infra-winmig-apac-v-chengzhiz-poc}"
BASTION_NAME="${BASTION_NAME:-bastion01}"
VM_NAME="${VM_NAME:-azmapp-lab01}"
RESOURCE_PORT="${RESOURCE_PORT:-3389}"
LOCAL_PORT="${LOCAL_PORT:-53389}"

if ! command -v az >/dev/null 2>&1; then
    echo "Azure CLI (az) is required on this Mac. Cloud Shell cannot host this local tunnel." >&2
    exit 127
fi

az account set --subscription "$SUBSCRIPTION_ID"
VM_ID="$(az vm show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --query id -o tsv)"

if [[ -z "$VM_ID" ]]; then
    echo "Could not determine resource ID for VM '$VM_NAME'." >&2
    exit 1
fi

printf 'Starting Bastion tunnel to %s. Keep this terminal open.\n' "$VM_NAME"
printf 'In Windows App, connect to 127.0.0.1:%s.\n' "$LOCAL_PORT"
exec az network bastion tunnel \
    --name "$BASTION_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --target-resource-id "$VM_ID" \
    --resource-port "$RESOURCE_PORT" \
    --port "$LOCAL_PORT"
