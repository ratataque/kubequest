#!/usr/bin/env bash
set -euo pipefail

# ===== Config (override via env) =====
ROLE="${ROLE:-control-plane}"                  # control-plane | worker
REPO_URL="${REPO_URL:-https://github.com/ratataque/kubequest.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
INSTALL_DIR="${INSTALL_DIR:-/opt/kubequest}"
K8S_REPO_DIR="${K8S_REPO_DIR:-${INSTALL_DIR}/kubernetes}"
GITOPS_REPO_DIR="${GITOPS_REPO_DIR:-${INSTALL_DIR}/gitops}"
BOOTSTRAP_GITOPS="${BOOTSTRAP_GITOPS:-true}"    # apply gitops/argocd/*.yaml Applications, control-plane only

K8S_SERIES="${K8S_SERIES:-v1.36}"
K8S_VERSION="${K8S_VERSION:-v1.36.1}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"         # flannel default
API_ADVERTISE_ADDRESS="${API_ADVERTISE_ADDRESS:-}"

GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.1.0}"
JOIN_COMMAND="${JOIN_COMMAND:-}"
INSTALL_NGINX="${INSTALL_NGINX:-true}"        # control-plane only
DEPLOY_STACK="${DEPLOY_STACK:-true}"          # control-plane only
SCHEDULE_ON_CONTROL_PLANE="${SCHEDULE_ON_CONTROL_PLANE:-true}"

log() { printf "\n[%s] %s\n" "$(date +'%F %T')" "$*"; }
need_cmd() { command -v "$1" >/dev/null 2>&1; }

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo bash bootstrap-ec2.sh"
  exit 1
fi

if ! need_cmd dnf; then
  echo "This script currently targets Amazon Linux 2023 (dnf)."
  exit 1
fi

if [[ "${ROLE}" != "control-plane" && "${ROLE}" != "worker" ]]; then
  echo "ROLE must be control-plane or worker"
  exit 1
fi

log "Installing base packages"
dnf install -y curl git ca-certificates iproute-tc conntrack-tools socat iscsi-initiator-utils
if [[ "${ROLE}" == "control-plane" && "${INSTALL_NGINX}" == "true" ]]; then
  dnf install -y nginx
fi

log "Enabling iSCSI for Longhorn"
systemctl enable --now iscsid

log "Kernel + sysctl prerequisites"
cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay || true
modprobe br_netfilter || true

cat >/etc/sysctl.d/99-kubernetes-cri.conf <<'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system >/dev/null

log "Disabling swap"
swapoff -a || true
# Only keep the very first (pristine) fstab backup across re-runs.
if [[ ! -f /etc/fstab.bak.kubequest ]]; then
  cp -a /etc/fstab /etc/fstab.bak.kubequest
fi
if [[ -f /etc/fstab ]]; then
  perl -0pi -e 's/^([^#].*\sswap\s+.*)$/# $1/gm' /etc/fstab
fi

log "Installing and configuring containerd"
dnf install -y containerd
mkdir -p /etc/containerd
# Only (re-)generate the default config once, so re-running the script doesn't
# wipe out any config drift/customization made outside this script.
if [[ ! -f /etc/containerd/config.toml ]]; then
  containerd config default >/etc/containerd/config.toml
fi
perl -0pi -e 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
systemctl enable --now containerd
systemctl restart containerd

log "Adding Kubernetes repo (${K8S_SERIES})"
cat >/etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/${K8S_SERIES}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/${K8S_SERIES}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

log "Installing kubelet/kubeadm/kubectl"
dnf install -y kubelet kubeadm kubectl --disableexcludes=kubernetes
systemctl enable --now kubelet

if [[ "${ROLE}" == "control-plane" ]]; then
  log "Initializing control-plane (if needed)"
  if [[ ! -f /etc/kubernetes/admin.conf ]]; then
    INIT_ARGS=(
      --kubernetes-version "${K8S_VERSION}"
      --pod-network-cidr "${POD_CIDR}"
      --cri-socket "unix:///run/containerd/containerd.sock"
    )
    if [[ -n "${API_ADVERTISE_ADDRESS}" ]]; then
      INIT_ARGS+=(--apiserver-advertise-address "${API_ADVERTISE_ADDRESS}")
    fi
    kubeadm init "${INIT_ARGS[@]}"
  fi

  mkdir -p /root/.kube
  cp -f /etc/kubernetes/admin.conf /root/.kube/config
  chmod 600 /root/.kube/config
  export KUBECONFIG=/etc/kubernetes/admin.conf

  log "Installing flannel CNI"
  kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

  if [[ "${SCHEDULE_ON_CONTROL_PLANE}" == "true" ]]; then
    kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true
  fi

  log "Waiting for node readiness"
  for _ in {1..120}; do
    if kubectl get nodes --no-headers 2>/dev/null | grep -q " Ready "; then
      break
    fi
    sleep 2
  done

  log "Persisting join command"
  kubeadm token create --print-join-command >/etc/kubernetes/join-command.sh
  chmod 700 /etc/kubernetes/join-command.sh

  if [[ "${DEPLOY_STACK}" == "true" ]]; then
    log "Installing Helm (if missing)"
    if ! need_cmd helm; then
      curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    fi

    log "Cloning/updating repo"
    if [[ -d "${INSTALL_DIR}/.git" ]]; then
      git -C "${INSTALL_DIR}" fetch --all --prune
      git -C "${INSTALL_DIR}" checkout "${REPO_BRANCH}"
      git -C "${INSTALL_DIR}" pull --ff-only origin "${REPO_BRANCH}"
    else
      git clone --branch "${REPO_BRANCH}" "${REPO_URL}" "${INSTALL_DIR}"
    fi

    log "Installing Gateway API CRDs"
    kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

    log "Installing Traefik"
    helm repo add traefik https://traefik.github.io/charts >/dev/null 2>&1 || true
    helm repo update
    helm upgrade --install traefik traefik/traefik \
      --namespace traefik \
      --create-namespace \
      -f "${K8S_REPO_DIR}/traefik-ingress/values.yaml"
    kubectl -n traefik rollout status deploy/traefik --timeout=180s \
      || log "Traefik rollout not confirmed within timeout, continuing (best effort)"

    log "Installing Longhorn"
    helm repo add longhorn https://charts.longhorn.io >/dev/null 2>&1 || true
    helm repo update
    kubectl create namespace longhorn-system --dry-run=client -o yaml | kubectl apply -f -
    helm upgrade --install longhorn longhorn/longhorn \
      --namespace longhorn-system \
      --create-namespace \
      -f "${K8S_REPO_DIR}/infrastructure/longhorn/values.yaml"
    kubectl -n longhorn-system wait --for=condition=Ready pod --all --timeout=600s \
      || log "Longhorn pods not all Ready within timeout, continuing (best effort)"
    kubectl get sc longhorn >/dev/null

    log "Applying additional Longhorn storage classes"
    kubectl apply -f "${K8S_REPO_DIR}/infrastructure/storage/longhorn-2-replicas.yaml"

    log "Installing Argo CD"
    helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
    helm repo update
    helm upgrade --install argocd argo/argo-cd \
      --namespace argocd \
      --create-namespace \
      -f "${K8S_REPO_DIR}/infrastructure/argocd/values.yaml"
    kubectl -n argocd wait --for=condition=Available deployment \
      -l app.kubernetes.io/name=argocd-server \
      --timeout=300s \
      || log "Argo CD server not Available within timeout, continuing (best effort)"

    log "Installing Sealed Secrets controller"
    helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets >/dev/null 2>&1 || true
    helm repo update
    helm upgrade --install sealed-secrets-controller sealed-secrets/sealed-secrets \
      --namespace sealed-secrets \
      --create-namespace \
      --set-string fullnameOverride=sealed-secrets-controller
    kubectl -n sealed-secrets wait --for=condition=Available deployment \
      -l app.kubernetes.io/name=sealed-secrets \
      --timeout=300s \
      || log "Sealed Secrets controller not Available within timeout, continuing (best effort)"

    log "Creating application namespaces"
    kubectl apply -f "${K8S_REPO_DIR}/apps/metrics/metrics-namespace.yaml"
    kubectl create namespace registry --dry-run=client -o yaml | kubectl apply -f -

    log "Installing Grafana"
    helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
    helm repo update
    helm upgrade --install grafana grafana/grafana \
      --namespace metrics \
      --create-namespace \
      -f "${K8S_REPO_DIR}/infrastructure/grafana/values.yaml"
    kubectl -n metrics rollout status deploy/grafana --timeout=180s \
      || log "Grafana rollout not confirmed within timeout, continuing (best effort)"

    log "Installing kube-prometheus-stack"
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
    helm repo update
    helm upgrade --install kube-prometheus prometheus-community/kube-prometheus-stack \
      --namespace metrics \
      --create-namespace \
      -f "${K8S_REPO_DIR}/infrastructure/kube-prometheus/values.yaml"

    log "Installing Loki"
    helm upgrade --install loki grafana/loki \
      --namespace metrics \
      --create-namespace \
      -f "${K8S_REPO_DIR}/infrastructure/loki/values.yaml"

    log "Installing Alloy (log shipper -> Loki)"
    helm upgrade --install alloy grafana/alloy \
      --namespace metrics \
      --create-namespace \
      -f "${K8S_REPO_DIR}/infrastructure/alloy/values.yaml"

    log "Installing Headlamp"
    helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/ >/dev/null 2>&1 || true
    helm repo update
    helm upgrade --install headlamp headlamp/headlamp \
      --namespace kube-system \
      -f "${K8S_REPO_DIR}/infrastructure/headlamp/values.yaml"
    kubectl -n kube-system rollout status deploy/headlamp --timeout=180s \
      || log "Headlamp rollout not confirmed within timeout, continuing (best effort)"

    log "Applying gateway, reference grants and Traefik middlewares"
    kubectl apply -f "${K8S_REPO_DIR}/infrastructure/gateway.yaml"
    kubectl apply -f "${K8S_REPO_DIR}/infrastructure/argocd/reference-grant.yaml"
    kubectl apply -f "${K8S_REPO_DIR}/infrastructure/longhorn/reference-grant.yaml"
    kubectl apply -f "${K8S_REPO_DIR}/infrastructure/grafana/reference-grant.yaml"
    kubectl apply -f "${K8S_REPO_DIR}/infrastructure/kube-prometheus/reference-grant.yaml"
    kubectl apply -f "${K8S_REPO_DIR}/infrastructure/loki/reference-grant.yaml"
    kubectl apply -f "${K8S_REPO_DIR}/infrastructure/headlamp/reference-grant.yaml"
    kubectl apply -f "${K8S_REPO_DIR}/infrastructure/secrets/traefik/metrics-auth.sealed-secret.yaml"
    kubectl apply -f "${K8S_REPO_DIR}/infrastructure/middlewares/traefik/metrics-basic-auth.yaml"
    kubectl apply -f "${K8S_REPO_DIR}/infrastructure/middlewares/traefik/strip-first-segment.yaml"

    log "Applying app manifests"
    kubectl apply -f "${K8S_REPO_DIR}/apps/metrics/argocd/http-route.yaml"
    kubectl apply -f "${K8S_REPO_DIR}/apps/metrics/grafana/http-route.yaml"
    kubectl apply -f "${K8S_REPO_DIR}/apps/metrics/headlamp/http-route.yaml"
    kubectl apply -f "${K8S_REPO_DIR}/apps/metrics/kube-prometheus/http-route.yaml"
    kubectl apply -f "${K8S_REPO_DIR}/apps/metrics/loki/http-route.yaml"
    kubectl apply -f "${K8S_REPO_DIR}/apps/metrics/longhorn/http-route.yaml"
    kubectl apply -f "${K8S_REPO_DIR}/apps/metrics/traefik/dashbaord-routes-ingress.yaml"
    kubectl apply -f "${K8S_REPO_DIR}/apps/metrics/traefik/metrics-route.yaml"
    kubectl apply -f "${K8S_REPO_DIR}/apps/whoami/deployement.yaml"
    kubectl apply -f "${K8S_REPO_DIR}/apps/whoami/http-route.yaml"
    kubectl apply -f "${K8S_REPO_DIR}/infrastructure/secrets/registry/registry-auth.secret.sealed-secret.yaml"
    kubectl apply -f "${K8S_REPO_DIR}/apps/registry/deployment.yaml"
    kubectl apply -f "${K8S_REPO_DIR}/apps/registry/http-route.yaml"

    log "Bootstrapping Argo CD applications (GitOps root)"
    if [[ "${BOOTSTRAP_GITOPS}" == "true" ]]; then
      kubectl apply -f "${GITOPS_REPO_DIR}/argocd/pull-secrets.yaml"
      kubectl apply -f "${GITOPS_REPO_DIR}/argocd/sample-app-dev.yaml"
      kubectl apply -f "${GITOPS_REPO_DIR}/argocd/sample-app-prod.yaml"
      kubectl apply -f "${GITOPS_REPO_DIR}/argocd/metrics-dashboard.yaml"
    fi

    if [[ "${INSTALL_NGINX}" == "true" ]]; then
      log "Linking nginx conf.d tree from repo"
      NGINX_SOURCE_DIR="${K8S_REPO_DIR}/nginx/conf.d"
      NGINX_TARGET_DIR="/etc/nginx/conf.d"

      if [[ ! -d "${NGINX_SOURCE_DIR}" ]]; then
        echo "Missing nginx source directory: ${NGINX_SOURCE_DIR}"
        exit 1
      fi

      # Mirror every subdirectory that exists in the repo tree (sites-enabled, snippets, upstreams, ...)
      # and re-link every *.conf file found, instead of hardcoding filenames one by one.
      while IFS= read -r -d '' repo_subdir; do
        mkdir -p "${NGINX_TARGET_DIR}/${repo_subdir}"
        find "${NGINX_TARGET_DIR}/${repo_subdir}" -maxdepth 1 -type l -delete
      done < <(find "${NGINX_SOURCE_DIR}" -mindepth 1 -maxdepth 1 -type d -printf '%f\0')
      find "${NGINX_TARGET_DIR}" -maxdepth 1 -type l -delete

      while IFS= read -r -d '' conf_file; do
        rel_path="${conf_file#"${NGINX_SOURCE_DIR}"/}"
        ln -sfn "${conf_file}" "${NGINX_TARGET_DIR}/${rel_path}"
      done < <(find "${NGINX_SOURCE_DIR}" -maxdepth 2 -type f -name '*.conf' -print0)

      nginx -t
      systemctl enable --now nginx
      systemctl restart nginx
    fi
  fi

  log "Control-plane ready"
  echo "Join command:"
  cat /etc/kubernetes/join-command.sh
  kubectl get nodes -o wide
  kubectl -n traefik get svc traefik -o wide || true
fi

if [[ "${ROLE}" == "worker" ]]; then
  log "Joining worker node"
  if [[ -f /etc/kubernetes/kubelet.conf ]]; then
    log "Worker already joined, skipping"
    exit 0
  fi

  if [[ -z "${JOIN_COMMAND}" ]]; then
    echo "For workers, provide JOIN_COMMAND env var from control-plane /etc/kubernetes/join-command.sh"
    exit 1
  fi

  ${JOIN_COMMAND} --cri-socket unix:///run/containerd/containerd.sock
  log "Worker join requested"
fi
