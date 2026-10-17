#!/usr/bin/env bash
set -euo pipefail

# Self-wrap with 1Password Environments if required variables are missing
if [[ -z "${RESOURCE_GROUP:-}" || -z "${CLUSTER_NAME:-}" ]]; then
    if [[ -n "${OP_ENV_ID:-}" ]]; then
        echo "Injecting variables from 1Password Environment (${OP_ENV_ID})..."
        exec op run --environment "${OP_ENV_ID}" -- "$0" "$@"
    else
        echo "Error: Cluster environment variables are not detected in the current shell."
        echo ""
        echo "Execute with 1Password Environments:"
        echo "  op run --environment <ENVIRONMENT_ID> -- $0 [command]"
        echo ""
        echo "Or export your Environment ID once in your terminal session:"
        echo "  export OP_ENV_ID=\"<ENVIRONMENT_ID>\""
        echo "  $0 [command]"
        exit 1
    fi
fi

# Configuration defaults if not populated by the 1Password Environment
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-aks-security-lab}"
LOCATION="${LOCATION:-eastus2}"
CLUSTER_NAME="${CLUSTER_NAME:-aks-ebpf-demo}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-<YOUR_AZURE_SUBSCRIPTION_ID>}"
NODE_VM_SIZE="${NODE_VM_SIZE:-Standard_D4s_v3}"

# Verify active Azure CLI authentication
ensure_auth() {
    if ! az account show >/dev/null 2>&1; then
        echo "Azure CLI session expired. Authenticating via 1Password..."
        if [[ -n "${ARM_CLIENT_ID:-}" && -n "${ARM_CLIENT_SECRET:-}" && -n "${ARM_TENANT_ID:-}" ]]; then
            az login --service-principal \
                --username "${ARM_CLIENT_ID}" \
                --password "${ARM_CLIENT_SECRET}" \
                --tenant "${ARM_TENANT_ID}"
        elif [[ -n "${OP_VAULT:-}" && -n "${OP_SP_ITEM:-}" ]]; then
            az login --service-principal \
                --username "$(op read "op://${OP_VAULT}/${OP_SP_ITEM}/appId")" \
                --password "$(op read "op://${OP_VAULT}/${OP_SP_ITEM}/password")" \
                --tenant "$(op read "op://${OP_VAULT}/${OP_SP_ITEM}/tenantId")"
        else
            az-login || az login
        fi
        az account set --subscription "${SUBSCRIPTION_ID}"
    fi
}

# Lifecycle subcommands
case "${1:-status}" in
    create)
        ensure_auth
        echo "Creating Azure resource group ${RESOURCE_GROUP} in ${LOCATION}..."
        az group create \
            --name "${RESOURCE_GROUP}" \
            --location "${LOCATION}" \
            --output table

        echo "Provisioning AKS cluster ${CLUSTER_NAME} with node size ${NODE_VM_SIZE}..."
        az aks create \
            --resource-group "${RESOURCE_GROUP}" \
            --name "${CLUSTER_NAME}" \
            --node-count 1 \
            --node-vm-size "${NODE_VM_SIZE}" \
            --os-sku Ubuntu \
            --enable-managed-identity \
            --generate-ssh-keys \
            --tier free

        echo "Merging cluster credentials into local kubeconfig..."
        az aks get-credentials \
            --resource-group "${RESOURCE_GROUP}" \
            --name "${CLUSTER_NAME}" \
            --overwrite-existing

        echo "Waiting for node readiness..."
        kubectl wait --for=condition=Ready node --all --timeout=180s
        kubectl get nodes -o wide
        echo "Cluster is created and ready for application deployment."
        ;;

    start)
        ensure_auth
        echo "Powering on AKS cluster ${CLUSTER_NAME}..."
        az aks start \
            --resource-group "${RESOURCE_GROUP}" \
            --name "${CLUSTER_NAME}"
        
        echo "Merging cluster credentials into local kubeconfig..."
        az aks get-credentials \
            --resource-group "${RESOURCE_GROUP}" \
            --name "${CLUSTER_NAME}" \
            --overwrite-existing
        
        echo "Waiting for node readiness..."
        kubectl wait --for=condition=Ready node --all --timeout=120s
        kubectl get nodes -o wide

        if kubectl get namespace voting-app >/dev/null 2>&1; then
            echo "Waiting for voting-app microservices to become ready..."
            kubectl rollout status deployment -n voting-app --timeout=120s
            echo "Seeding baseline vote traffic (re-populating emptyDir Redis & PostgreSQL storage)..."
            kubectl run seed-votes --rm -i --restart=Never --image=curlimages/curl:latest -n voting-app -- \
                sh -c 'for i in 1 2 3 4 5; do curl -s -X POST -d "vote=a" http://vote:8080/ >/dev/null; curl -s -X POST -d "vote=b" http://vote:8080/ >/dev/null; done; echo "10 baseline votes (5 Cats, 5 Dogs) seeded across vote -> redis -> worker -> db!"' || true
            kubectl get pods -n voting-app -o wide
        fi
        echo "Cluster is running and ready for practice."
        ;;

    stop)
        ensure_auth
        echo "Stopping AKS cluster ${CLUSTER_NAME} to halt VM compute charges..."
        az aks stop \
            --resource-group "${RESOURCE_GROUP}" \
            --name "${CLUSTER_NAME}"
        echo "Cluster stopped. Configuration preserved with zero active node charges."
        ;;

    status)
        ensure_auth
        echo "Checking power state for ${CLUSTER_NAME}..."
        STATE=$(az aks show \
            --resource-group "${RESOURCE_GROUP}" \
            --name "${CLUSTER_NAME}" \
            --query "powerState.code" \
            --output tsv 2>/dev/null || echo "NotFound")
        echo "Cluster Power State: ${STATE}"

        if [[ "${STATE}" == "Running" ]]; then
            echo ""
            echo "Kubernetes Node Status:"
            kubectl get nodes 2>/dev/null || echo "Unable to reach API server."
            echo ""
            echo "Workload Status in voting-app namespace:"
            kubectl get pods -n voting-app 2>/dev/null || echo "No voting-app namespace found."
            echo ""
            echo "Sysdig Shield Agent Status in sysdig-agent namespace:"
            kubectl get pods -n sysdig-agent 2>/dev/null || echo "No sysdig-agent namespace found."
        fi
        ;;

    deploy-agent)
        ensure_auth
        if [[ -z "${SYSDIG_ACCESS_KEY:-}" ]]; then
            if [[ -n "${OP_ENV_ID:-}" ]]; then
                echo "Injecting SYSDIG_ACCESS_KEY from 1Password Environment (${OP_ENV_ID})..."
                exec op run --environment "${OP_ENV_ID}" -- "$0" "$@"
            else
                echo "Error: SYSDIG_ACCESS_KEY is not set in the current environment."
                echo "Ensure SYSDIG_ACCESS_KEY is added to your 1Password Environment and run:"
                echo "  op run --environment <ENVIRONMENT_ID> -- $0 deploy-agent"
                exit 1
            fi
        fi

        SYSDIG_REGION="${SYSDIG_REGION:-us4}"
        echo "Adding and updating official Sysdig Helm chart repository..."
        helm repo add sysdig https://charts.sysdig.com --force-update
        helm repo update

        echo "Deploying Sysdig Shield to cluster ${CLUSTER_NAME} (Region: ${SYSDIG_REGION})..."
        helm upgrade --install sysdig-shield sysdig/sysdig-deploy \
            --namespace sysdig-agent \
            --create-namespace \
            --set global.sysdig.accessKey="${SYSDIG_ACCESS_KEY}" \
            --set global.sysdig.region="${SYSDIG_REGION}" \
            --set global.clusterName="${CLUSTER_NAME}" \
            --set nodeAnalyzer.enabled=true \
            --set nodeAnalyzer.nodeAnalyzer.runtimeScanner.deploy=true \
            --set kspmCollector.enabled=true \
            --set admissionController.enabled=false

        echo "Waiting for Sysdig Shield pods to initialize..."
        sleep 5
        kubectl get pods -n sysdig-agent -o wide
        ;;

    connect)
        ensure_auth
        echo "Refreshing credentials for ${CLUSTER_NAME}..."
        az aks get-credentials \
            --resource-group "${RESOURCE_GROUP}" \
            --name "${CLUSTER_NAME}" \
            --overwrite-existing
        kubectl get nodes -o wide
        ;;

    cost)
        ensure_auth
        echo "Querying Month-to-Date Azure Cost Management breakdown for subscription ${SUBSCRIPTION_ID}..."
        az rest --method post \
            --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.CostManagement/query?api-version=2023-11-01" \
            --body '{"type":"ActualCost","timeframe":"MonthToDate","dataset":{"granularity":"None","aggregation":{"totalCost":{"name":"Cost","function":"Sum"}},"grouping":[{"type":"Dimension","name":"ServiceName"}]}}' \
            --output json | python3 -c '
import sys, json
data = json.load(sys.stdin)
rows = data.get("properties", {}).get("rows", [])
print("\n{:<28} {:>18} {:>10}".format("Azure Service", "Month-to-Date Cost", "Currency"))
print("-" * 58)
total = 0.0
for cost, service, currency in sorted(rows, key=lambda x: x[0], reverse=True):
    total += float(cost)
    print("{:<28} ${:>17.4f} {:>10}".format(service, float(cost), currency))
print("-" * 58)
print("{:<28} ${:>17.2f} {:>10}\n".format("TOTAL MONTH-TO-DATE SPEND", total, "USD"))
'
        ;;

    delete)
        ensure_auth
        echo "Deleting AKS cluster ${CLUSTER_NAME}..."
        az aks delete \
            --resource-group "${RESOURCE_GROUP}" \
            --name "${CLUSTER_NAME}" \
            --yes --no-wait
        echo "Cluster deletion initiated in background."
        ;;

    *)
        echo "Usage: $0 {create|start|stop|status|deploy-agent|cost|connect|delete}"
        exit 1
        ;;
esac
