# AKS eBPF Runtime Security & Cloud Posture Lab (`aks-ebpf-security-lab`)

A cloud-native Kubernetes security laboratory built on **Azure Kubernetes Service (AKS)** to evaluate **eBPF runtime threat detection (Falco)**, **In-Use runtime vulnerability prioritization**, and **Cloud/Kubernetes Security Posture Management (CSPM / KSPM / CIEM)** against a polyglot 5-tier microservices architecture.

---

## Architecture Overview

1. **Infrastructure & Cost Governance (`scripts/cluster.sh`):**
   - Provisions a managed AKS cluster (`Standard_D4s_v3`) with zero plaintext credentials on disk using **1Password Environments (`op run`)**.
   - Includes automated cluster lifecycle controls (`start`, `stop`, `status`, `cost`, `connect`) utilizing native Azure VM deallocation (`az aks stop` / `az aks start`) and the **Microsoft Cost Management API** for real-time spend tracking.
   - Automatically seeds baseline HTTP traffic across all microservices upon cluster startup (`cluster.sh start`) to populate ephemeral `emptyDir` storage and load runtime shared libraries into kernel memory.
2. **Polyglot Microservices Target (`manifests/voting-app/`):**
   - Deploys a 5-tier microservices application isolated inside the `voting-app` namespace:
     - `vote`: Python / Flask / Gunicorn frontend
     - `redis`: In-memory message queue
     - `worker`: .NET Core background queue processor
     - `db`: PostgreSQL database
     - `result`: Node.js / Express / Socket.io real-time results UI
3. **CNAPP & eBPF Runtime Sensor Integration (`sysdig/`):**
   - **Cloud Account Posture & CIEM (`sysdig/azure-onboarding/main.tf.example`):** Terraform modules provisioning least-privilege Entra ID Service Principals (`Reader` + `Security Reader`) for continuous cloud inventory, CIS Azure Benchmark compliance, and identity entitlement analysis.
   - **In-Cluster eBPF Sensor (`sysdig/helm-values.yaml`):** Helm configuration deploying the eBPF runtime sensor, In-Use memory vulnerability scanner, and KSPM posture collector.
4. **Adversary Emulation & Runtime Forensics (`scripts/simulate_attack.sh`):**
   - Executes a 4-stage post-exploitation sequence inside the `vote` container (system reconnaissance, `/etc/passwd` sensitive file read, outbound payload ingress via `wget`/`curl`, and executable drop in `/tmp`) to validate real-time Falco syscall detection and process-tree forensics.

---

## Quick Start

```bash
# 1. Manage AKS cluster lifecycle with 1Password Environments
export OP_ENV_ID="<YOUR_1PASSWORD_ENV_ID>"
./scripts/cluster.sh status
./scripts/cluster.sh start
./scripts/cluster.sh cost

# 2. Deploy the 5-tier microservices workload into the 'voting-app' namespace
kubectl apply -f manifests/voting-app/
kubectl get pods,svc -n voting-app -o wide

# 3. Execute live adversary simulation for eBPF runtime detection
./scripts/simulate_attack.sh run

# 4. Suspend cluster compute billing when finished
./scripts/cluster.sh stop
```
