#!/usr/bin/env bash
# Ek baar chalao (Git Bash ya WSL me): az login + gh auth login pehle ho chuka hona chahiye.
set -euo pipefail

LOCATION="${LOCATION:-centralindia}"
TF_RG="rg-tfstate-sms"
CONTAINER="tfstate"
APP_NAME="sp-github-sms"

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
SUB_ID="$(az account show --query id -o tsv)"
TENANT_ID="$(az account show --query tenantId -o tsv)"
SA="sttfstate$(echo -n "$SUB_ID" | sha256sum | cut -c1-10)"

echo ">> Repo: $REPO | Subscription: $SUB_ID"

echo ">> Terraform state storage"
az group create -n "$TF_RG" -l "$LOCATION" -o none
az storage account create -n "$SA" -g "$TF_RG" -l "$LOCATION" --sku Standard_LRS \
  --min-tls-version TLS1_2 --allow-blob-public-access false -o none
az storage container create -n "$CONTAINER" --account-name "$SA" --auth-mode login -o none || true

echo ">> App registration (GitHub OIDC)"
APP_ID="$(az ad app list --display-name "$APP_NAME" --query '[0].appId' -o tsv)"
if [ -z "$APP_ID" ]; then
  APP_ID="$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)"
  az ad sp create --id "$APP_ID" -o none
  sleep 20
fi

add_cred () {
  local name="$1" subject="$2"
  if ! az ad app federated-credential list --id "$APP_ID" --query "[?name=='$name']" -o tsv | grep -q .; then
    az ad app federated-credential create --id "$APP_ID" --parameters "{
      \"name\":\"$name\",
      \"issuer\":\"https://token.actions.githubusercontent.com\",
      \"subject\":\"$subject\",
      \"audiences\":[\"api://AzureADTokenExchange\"]}" -o none
  fi
}
add_cred gh-main "repo:${REPO}:ref:refs/heads/main"
add_cred gh-pr   "repo:${REPO}:pull_request"

echo ">> Role assignments"
SCOPE="/subscriptions/$SUB_ID"
az role assignment create --assignee "$APP_ID" --role "Contributor" --scope "$SCOPE" -o none || true
# Terraform ko AKS->ACR AcrPull role assign karna hai, isliye ye chahiye
az role assignment create --assignee "$APP_ID" --role "User Access Administrator" --scope "$SCOPE" -o none || true
SA_ID="$(az storage account show -n "$SA" -g "$TF_RG" --query id -o tsv)"
az role assignment create --assignee "$APP_ID" --role "Storage Blob Data Contributor" --scope "$SA_ID" -o none || true

echo ">> GitHub secrets / variables"
gh secret set AZURE_CLIENT_ID       --body "$APP_ID"
gh secret set AZURE_TENANT_ID       --body "$TENANT_ID"
gh secret set AZURE_SUBSCRIPTION_ID --body "$SUB_ID"
gh variable set TFSTATE_RG        --body "$TF_RG"
gh variable set TFSTATE_SA        --body "$SA"
gh variable set TFSTATE_CONTAINER --body "$CONTAINER"

echo "Done. Ab code push karo aur Actions me 'infra' workflow chalao."
