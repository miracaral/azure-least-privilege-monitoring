#!/bin/bash
# Rebuilds the lab in Azure Cloud Shell. Set these first.
RG=rg-portfolio
LOCATION=francecentral
VAULT_NAME=kv-yourname-$RANDOM
IDENTITY_NAME=id-portfolio-deploy      # managed identity used by GitHub Actions (OIDC)
ALERT_EMAIL=you@example.com
set -e

for namespace in Microsoft.KeyVault Microsoft.OperationalInsights Microsoft.Insights Microsoft.AlertsManagement; do
  az provider register --namespace $namespace --wait
done

# Key Vault in RBAC mode with two test secrets
az keyvault create -n $VAULT_NAME -g $RG -l $LOCATION --enable-rbac-authorization true --retention-days 7 -o none
VAULT_ID=$(az keyvault show -n $VAULT_NAME --query id -o tsv)
MY_ID=$(az ad signed-in-user show --query id -o tsv)
az role assignment create --assignee-object-id $MY_ID --assignee-principal-type User \
  --role "Key Vault Secrets Officer" --scope $VAULT_ID -o none
sleep 60
az keyvault secret set --vault-name $VAULT_NAME -n app-secret --value "hello-from-keyvault" -o none
az keyvault secret set --vault-name $VAULT_NAME -n admin-secret --value "you-should-not-see-this" -o none

# The deploy identity may read one secret only
PRINCIPAL_ID=$(az identity show -n $IDENTITY_NAME -g $RG --query principalId -o tsv)
az role assignment create --assignee-object-id $PRINCIPAL_ID --assignee-principal-type ServicePrincipal \
  --role "Key Vault Secrets User" --scope "$VAULT_ID/secrets/app-secret" -o none

# Audit logs to Log Analytics
az monitor log-analytics workspace create -g $RG -n law-portfolio -l $LOCATION --retention-time 30 -o none
WORKSPACE_ID=$(az monitor log-analytics workspace show -g $RG -n law-portfolio --query id -o tsv)
az monitor diagnostic-settings create -n kv-audit --resource $VAULT_ID --workspace $WORKSPACE_ID \
  --logs '[{"category":"AuditEvent","enabled":true}]' -o none

# Email alert on a denied secret read (the address must be verified once by email)
az monitor action-group create -g $RG -n ag-email --short-name mailme --action email me $ALERT_EMAIL -o none
ACTION_GROUP_ID=$(az monitor action-group show -g $RG -n ag-email --query id -o tsv)
az monitor scheduled-query create -g $RG -n kv-denied-access --scopes $WORKSPACE_ID --location $LOCATION \
  --condition "count 'Denied' > 0" \
  --condition-query Denied="AzureDiagnostics | where ResourceProvider == 'MICROSOFT.KEYVAULT' and OperationName == 'SecretGet' and httpStatusCode_d == 403" \
  --evaluation-frequency 5m --window-size 5m --severity 2 --action-groups $ACTION_GROUP_ID \
  --description "Someone was denied a Key Vault secret" -o none

# Monthly budget, email at 80%
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
az rest --method put \
  --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Consumption/budgets/student-guard?api-version=2023-05-01" \
  --body "{\"properties\":{\"category\":\"Cost\",\"amount\":5,\"timeGrain\":\"Monthly\",\"timePeriod\":{\"startDate\":\"$(date +%Y-%m-01)T00:00:00Z\",\"endDate\":\"$(date -d '+1 year' +%Y-%m-01)T00:00:00Z\"},\"notifications\":{\"Actual_80\":{\"enabled\":true,\"operator\":\"GreaterThan\",\"threshold\":80,\"contactEmails\":[\"$ALERT_EMAIL\"]}}}}" -o none

echo "done: vault $VAULT_NAME"
