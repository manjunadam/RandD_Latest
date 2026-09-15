#!/usr/bin/env bash
# One-shot deployment of the stack (one Web App + one Storage account). Requires: az cli (logged in), node 20, npm.
set -euo pipefail
ENV="${1:-dev}"; RG="${RG:-rg-nhsc-rd-stability-$ENV}"; LOC="${LOC:-eastus2}"
TENANT_ID="$(az account show --query tenantId -o tsv)"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

echo "== 1/6 Entra app registration (API) with app roles"
API_APP_ID=$(az ad app list --display-name "Stability Capture API ($ENV)" --query "[0].appId" -o tsv)
if [ -z "$API_APP_ID" ]; then
  API_APP_ID=$(az ad app create --display-name "Stability Capture API ($ENV)" --sign-in-audience AzureADMyOrg --app-roles @"$ROOT/backend/infra/entra-app-roles.json" --query appId -o tsv)
  az ad app update --id "$API_APP_ID" --identifier-uris "api://stability-capture-api-$ENV"
  az ad sp create --id "$API_APP_ID" >/dev/null
fi
SPA_APP_ID=$(az ad app list --display-name "Stability Capture SPA ($ENV)" --query "[0].appId" -o tsv)
if [ -z "$SPA_APP_ID" ]; then
  SPA_APP_ID=$(az ad app create --display-name "Stability Capture SPA ($ENV)" --sign-in-audience AzureADMyOrg --query appId -o tsv)
fi
echo "API app: $API_APP_ID   SPA app: $SPA_APP_ID"
echo "   -> In the portal: expose scope 'access_as_user' on the API app, grant it to the SPA app, add the SPA redirect URI after step 2, assign users to app roles."

echo "== 2/6 Resource group + Bicep"
az group create -n "$RG" -l "$LOC" -o none
az deployment group create -g "$RG" -f "$ROOT/backend/infra/main.bicep" \
  -p env="$ENV" entraTenantId="$TENANT_ID" entraApiAudience="api://stability-capture-api-$ENV" -o none
WEB=$(az deployment group show -g "$RG" -n main --query properties.outputs.webAppUrl.value -o tsv)
APP_NAME=$(basename "$WEB" | cut -d. -f1)
echo "Web app: $WEB"

echo "== 3/6 Build the React app for this environment"
cat > "$ROOT/frontend/.env.production" <<ENVEOF
VITE_API_BASE=
VITE_AUTH_MODE=msal
VITE_ENTRA_CLIENT_ID=$SPA_APP_ID
VITE_ENTRA_TENANT_ID=$TENANT_ID
VITE_API_SCOPE=api://stability-capture-api-$ENV/access_as_user
ENVEOF
(cd "$ROOT/frontend" && npm ci && npm run build)

echo "== 4/6 Package and deploy (frontend/dist + backend/api)"
TMP=$(mktemp -d); mkdir -p "$TMP/frontend" "$TMP/backend"
cp -r "$ROOT/frontend/dist" "$TMP/frontend/dist"; cp -r "$ROOT/backend/api" "$TMP/backend/api"; rm -rf "$TMP/backend/api/node_modules"
cat > "$TMP/package.json" <<'PKG'
{ "name": "stability-capture-webapp", "private": true, "scripts": { "start": "npm start --prefix backend/api", "postinstall": "npm ci --omit=dev --omit=optional --prefix backend/api" } }
PKG
(cd "$TMP" && zip -qr deploy.zip .)
az webapp deploy -g "$RG" -n "$APP_NAME" --src-path "$TMP/deploy.zip" --type zip -o none

echo "== 5/6 Register the SPA redirect URI"
az ad app update --id "$SPA_APP_ID" --set spa.redirectUris="[\"$WEB\"]" 2>/dev/null || az ad app update --id "$SPA_APP_ID" --web-redirect-uris "$WEB"

echo "== 6/6 Done. Next: load reference data (Admin > Reference data, or: cd backend/api && STORAGE_ACCOUNT_NAME=<account> npm run import-reference -- --csv-dir <nestms-export>) and assign users to app roles."
echo "Health: $WEB/api/health"
