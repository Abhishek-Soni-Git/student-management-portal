#!/usr/bin/env bash
# bootstrap.sh - one-time, idempotent setup. Safe to re-run.
# Run from Git Bash or WSL AFTER: `az login` (correct subscription) and `gh auth login`.
#
# What it creates
#   Azure : 2 resource groups, hardened Terraform-state storage account (+ delete lock),
#           3 least-privilege identities (plan / infra-apply / deploy) with GitHub OIDC
#           federated credentials, scoped role assignments (NO subscription-wide Contributor).
#   GitHub: environments (infra-apply, prod) restricted to main, repo variables (IDs only, no secrets),
#           a random Mongo password stored as an environment secret, best-effort branch protection.
set -euo pipefail

# Git Bash (MSYS) rewrites "/subscriptions/..." into a Windows path. Turn that off.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

LOCATION="${LOCATION:-centralindia}"
APP_RG="${APP_RG:-rg-sms-dev}"
AKS_NAME="${AKS_NAME:-aks-sms-dev}"
SUBJECT_FORMAT="${SUBJECT_FORMAT:-id}"   # id  = repo:OWNER@ID/REPO@ID:...  (what your repo emitted in the 401 error)
                                         # name = repo:OWNER/REPO:...
CLEANUP_LEGACY="${CLEANUP_LEGACY:-0}"    # 1 = delete the old over-privileged app 'sp-github-sms'

TF_RG="rg-tfstate-sms"
TF_CONTAINER="tfstate"
LEGACY_APP="sp-github-sms"

log()  { printf '\n>> %s\n' "$*"; }
warn() { printf '!! WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
azv()  { az "$@" | tr -d '\r'; }
ghv()  { gh "$@" | tr -d '\r'; }

# ---------- preflight ----------
for c in az gh openssl sha1sum sha256sum; do
  command -v "$c" >/dev/null 2>&1 || die "'$c' not found in PATH"
done
az account show >/dev/null 2>&1 || die "run 'az login' first"
gh auth status >/dev/null 2>&1  || die "run 'gh auth login' first"
case "$SUBJECT_FORMAT" in id|name) ;; *) die "SUBJECT_FORMAT must be id or name" ;; esac

REPO="$(ghv repo view --json nameWithOwner -q .nameWithOwner)"
OWNER="${REPO%%/*}"
NAME="${REPO##*/}"
OWNER_ID="$(ghv api "repos/$REPO" -q .owner.id)"
REPO_ID="$(ghv api "repos/$REPO" -q .id)"
GH_USER_ID="$(ghv api user -q .id)"
SUB_ID="$(azv account show --query id -o tsv)"
TENANT_ID="$(azv account show --query tenantId -o tsv)"

# Deterministic names (Terraform computes the same ACR name with sha1(subscription_id))
SA="sttfstate$(printf %s "$SUB_ID" | sha256sum | cut -c1-10)"
ACR_NAME="acrsms$(printf %s "$SUB_ID" | sha1sum | cut -c1-8)"

APP_RG_SCOPE="/subscriptions/$SUB_ID/resourceGroups/$APP_RG"

log "Repo: $REPO | Subscription: $SUB_ID | Region: $LOCATION | OIDC subject format: $SUBJECT_FORMAT"

# ---------- helpers ----------
ensure_app() {  # $1 = display name -> sets APP_ID and SP_OID
  local created=0
  APP_ID="$(azv ad app list --display-name "$1" --query '[0].appId' -o tsv)"
  if [ -z "$APP_ID" ]; then
    APP_ID="$(azv ad app create --display-name "$1" --query appId -o tsv)"
    created=1
  fi
  SP_OID="$(azv ad sp list --filter "appId eq '$APP_ID'" --query '[0].id' -o tsv)"
  if [ -z "$SP_OID" ]; then
    SP_OID="$(azv ad sp create --id "$APP_ID" --query id -o tsv)"
    created=1
  fi
  if [ "$created" = 1 ]; then sleep 15; fi   # Entra replication
}

subject() {  # $1 = claim suffix, e.g. environment:prod or pull_request
  if [ "$SUBJECT_FORMAT" = id ]; then
    printf 'repo:%s@%s/%s@%s:%s' "$OWNER" "$OWNER_ID" "$NAME" "$REPO_ID" "$1"
  else
    printf 'repo:%s:%s' "$REPO" "$1"
  fi
}

ensure_cred() {  # $1 = app id, $2 = credential name, $3 = subject
  local existing
  existing="$(azv ad app federated-credential list --id "$1" --query "[?name=='$2'].name" -o tsv)"
  if [ -n "$existing" ]; then
    azv ad app federated-credential delete --id "$1" --federated-credential-id "$2" -o none
  fi
  azv ad app federated-credential create --id "$1" --parameters "{
    \"name\":\"$2\",
    \"issuer\":\"https://token.actions.githubusercontent.com\",
    \"subject\":\"$3\",
    \"audiences\":[\"api://AzureADTokenExchange\"]}" -o none
}

ensure_role() {  # $1 = principal object id, $2 = role, $3 = scope, $4 = optional ABAC condition
  local n
  n="$(azv role assignment list --assignee "$1" --role "$2" --scope "$3" --query 'length(@)' -o tsv)"
  if [ "$n" = "0" ]; then
    if [ -n "${4:-}" ]; then
      azv role assignment create --assignee-object-id "$1" --assignee-principal-type ServicePrincipal \
        --role "$2" --scope "$3" --condition "$4" --condition-version 2.0 -o none
    else
      azv role assignment create --assignee-object-id "$1" --assignee-principal-type ServicePrincipal \
        --role "$2" --scope "$3" -o none
    fi
    echo "   + $2 @ ${3##*/}"
  else
    echo "   = $2 @ ${3##*/} (already set)"
  fi
}

# ---------- 1. resource groups ----------
log "Resource groups"
azv group create -n "$TF_RG"  -l "$LOCATION" --tags purpose=tfstate -o none
azv group create -n "$APP_RG" -l "$LOCATION" --tags app=student-management-portal -o none

# ---------- 2. hardened Terraform state storage ----------
log "Terraform state storage account: $SA"
if ! az storage account show -n "$SA" -g "$TF_RG" >/dev/null 2>&1; then
  az storage account create -n "$SA" -g "$TF_RG" -l "$LOCATION" --sku Standard_GRS -o none
fi
# Entra-ID auth only (no account keys), no public blobs, TLS 1.2+, HTTPS only
az storage account update -n "$SA" -g "$TF_RG" --sku Standard_GRS \
  --min-tls-version TLS1_2 --allow-blob-public-access false \
  --allow-shared-key-access false --https-only true -o none
# Versioning + soft delete = recover from a bad/corrupt state file
az storage account blob-service-properties update --account-name "$SA" -g "$TF_RG" \
  --enable-versioning true \
  --enable-delete-retention true --delete-retention-days 14 \
  --enable-container-delete-retention true --container-delete-retention-days 14 -o none
if ! az storage container-rm show --storage-account "$SA" -g "$TF_RG" --name "$TF_CONTAINER" >/dev/null 2>&1; then
  az storage container-rm create --storage-account "$SA" -g "$TF_RG" --name "$TF_CONTAINER" -o none
fi
if ! az lock show -n protect-tfstate -g "$TF_RG" >/dev/null 2>&1; then
  az lock create -n protect-tfstate --lock-type CanNotDelete -g "$TF_RG" -o none
fi
SA_ID="$(azv storage account show -n "$SA" -g "$TF_RG" --query id -o tsv)"

# ---------- 3. identities (one per trust level) ----------
log "Identities (GitHub OIDC, no client secrets)"

ensure_app "sp-gh-sms-plan";   PLAN_ID="$APP_ID";   PLAN_OID="$SP_OID"
ensure_app "sp-gh-sms-infra";  INFRA_ID="$APP_ID";  INFRA_OID="$SP_OID"
ensure_app "sp-gh-sms-deploy"; DEPLOY_ID="$APP_ID"; DEPLOY_OID="$SP_OID"

ensure_cred "$PLAN_ID"   gh-pull-request  "$(subject pull_request)"
ensure_cred "$INFRA_ID"  gh-env-infra-apply "$(subject environment:infra-apply)"
ensure_cred "$DEPLOY_ID" gh-env-prod      "$(subject environment:prod)"

# ---------- 4. least-privilege role assignments ----------
log "Role assignments"

# plan: read-only. Can see Azure + read state; cannot change anything. Used for pull requests.
ensure_role "$PLAN_OID" "Reader"                        "$APP_RG_SCOPE"
ensure_role "$PLAN_OID" "Storage Blob Data Reader"      "$SA_ID"

# infra-apply: Contributor ONLY on the app RG (not the subscription) + state access.
ensure_role "$INFRA_OID" "Contributor"                  "$APP_RG_SCOPE"
ensure_role "$INFRA_OID" "Storage Blob Data Contributor" "$SA_ID"

# infra-apply may create role assignments, but ONLY for these 5 roles (ABAC condition),
# so it can never grant itself Owner/Contributor:
#   AcrPull, AcrPush, AKS Cluster User, AKS RBAC Writer, AKS RBAC Cluster Admin
ROLE_IDS="7f951dda-4ed3-4680-a7ca-43fe172d538d, 8311e382-0749-4cb8-b61a-304f252e45ec, 4abbcc35-e782-43d8-92c5-2d3f1bd2253f, a7ffa36f-339b-4b5c-8bdf-e2c188b2c0eb, b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b"
COND="((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${ROLE_IDS}})) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${ROLE_IDS}}))"
ensure_role "$INFRA_OID" "Role Based Access Control Administrator" "$APP_RG_SCOPE" "$COND"

# deploy: gets ACR push + namespace-scoped AKS rights from Terraform (infra/main.tf), nothing here.

# ---------- 5. GitHub environments ----------
log "GitHub environments (restricted to main; manual approval where the plan allows)"
ensure_env() {  # $1 = environment name
  local env="$1" base_policy='"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}'
  if printf '{"reviewers":[{"type":"User","id":%s}],%s}' "$GH_USER_ID" "$base_policy" \
       | gh api -X PUT "repos/$REPO/environments/$env" --input - >/dev/null 2>&1; then
    :
  elif printf '{%s}' "$base_policy" | gh api -X PUT "repos/$REPO/environments/$env" --input - >/dev/null 2>&1; then
    warn "env '$env': required reviewers not available on this plan (private repo on Free). Branch restriction applied, approval gate NOT."
  else
    gh api -X PUT "repos/$REPO/environments/$env" >/dev/null 2>&1 \
      || die "could not create environment '$env'"
    warn "env '$env': created without reviewers or branch restriction (plan limitation). Make the repo public or upgrade to enforce them."
  fi
  # 422 = policy for 'main' already exists; that is fine on re-runs
  gh api -X POST "repos/$REPO/environments/$env/deployment-branch-policies" -f name=main >/dev/null 2>&1 || true
}
ensure_env infra-apply
ensure_env prod

# ---------- 6. GitHub variables + secret ----------
log "GitHub repository variables (identifiers only - none of these are secrets)"
setvar() { gh variable set "$1" --body "$2" --repo "$REPO" >/dev/null; echo "   $1"; }
setvar AZURE_TENANT_ID        "$TENANT_ID"
setvar AZURE_SUBSCRIPTION_ID  "$SUB_ID"
setvar PLAN_CLIENT_ID         "$PLAN_ID"
setvar INFRA_CLIENT_ID        "$INFRA_ID"
setvar DEPLOY_CLIENT_ID       "$DEPLOY_ID"
setvar DEPLOY_SP_OBJECT_ID    "$DEPLOY_OID"
setvar TFSTATE_RG             "$TF_RG"
setvar TFSTATE_SA             "$SA"
setvar TFSTATE_CONTAINER      "$TF_CONTAINER"
setvar APP_RG                 "$APP_RG"
setvar AKS_NAME               "$AKS_NAME"
setvar ACR_NAME               "$ACR_NAME"

log "Mongo password (random, stored only as a GitHub environment secret)"
existing_secrets="$(ghv api "repos/$REPO/environments/prod/secrets" -q '.secrets[].name' 2>/dev/null || true)"
if grep -qx MONGO_PASSWORD <<<"$existing_secrets"; then
  echo "   MONGO_PASSWORD already exists - keeping it (changing it would lock you out of existing data)"
else
  openssl rand -hex 24 | gh secret set MONGO_PASSWORD --env prod --repo "$REPO" >/dev/null
  echo "   MONGO_PASSWORD created"
fi

# ---------- 7. best-effort repo hardening ----------
log "Branch protection on main (best effort; needs a plan that supports it)"
if printf '%s' '{
  "required_status_checks": {"strict": false, "contexts": ["secret-scan","terraform-checks","image-scan"]},
  "enforce_admins": false,
  "required_pull_request_reviews": {"required_approving_review_count": 0},
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}' | gh api -X PUT "repos/$REPO/branches/main/protection" --input - >/dev/null 2>&1; then
  echo "   enabled (PR + passing CI required; admins can still bypass)"
else
  warn "branch protection not applied (private repo on Free plan, or main does not exist yet). Enable it manually in Settings > Branches."
fi

# ---------- 8. legacy cleanup ----------
LEGACY_ID="$(azv ad app list --display-name "$LEGACY_APP" --query '[0].appId' -o tsv)"
if [ -n "$LEGACY_ID" ]; then
  if [ "$CLEANUP_LEGACY" = 1 ]; then
    log "Removing legacy over-privileged app '$LEGACY_APP' (had Contributor + User Access Administrator on the whole subscription)"
    LEGACY_OID="$(azv ad sp list --filter "appId eq '$LEGACY_ID'" --query '[0].id' -o tsv)"
    if [ -n "$LEGACY_OID" ]; then
      for ra in $(azv role assignment list --assignee "$LEGACY_OID" --all --query '[].id' -o tsv); do
        az role assignment delete --ids "$ra" >/dev/null
      done
    fi
    az ad app delete --id "$LEGACY_ID"
  else
    warn "Legacy app '$LEGACY_APP' still exists with subscription-wide Contributor + User Access Administrator."
    warn "Remove it:  CLEANUP_LEGACY=1 bash scripts/bootstrap.sh"
  fi
fi

cat <<EOF

Done.
  Plan identity   : $PLAN_ID   (read-only, pull requests)
  Infra identity  : $INFRA_ID  (RG-scoped, environment infra-apply)
  Deploy identity : $DEPLOY_ID (ACR push + namespace RBAC, environment prod)
  State storage   : $SA / $TF_CONTAINER
  ACR (Terraform creates it): $ACR_NAME

Next: git add . && git commit && git push, then watch Actions: ci -> infra -> deploy.
EOF
