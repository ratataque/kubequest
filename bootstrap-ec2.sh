#!/usr/bin/env bash
set -euo pipefail

# ===== Config (override via env) =====
ROLE="${ROLE:-control-plane}"                  # control-plane | worker
REPO_URL="${REPO_URL:-https://github.com/ratataque/kubequest.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
INSTALL_DIR="${INSTALL_DIR:-/opt/kubequest}"

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
dnf install -y curl git ca-certificates iproute-tc conntrack-tools socat
if [[ "${ROLE}" == "control-plane" && "${INSTALL_NGINX}" == "true" ]]; then
  dnf install -y nginx
fi

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
cp -a /etc/fstab /etc/fstab.bak.kubequest
if [[ -f /etc/fstab ]]; then
  perl -0pi -e 's/^([^#].*\sswap\s+.*)$/# $1/gm' /etc/fstab
fi

log "Installing and configuring containerd"
dnf install -y containerd
mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
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
      -f "${INSTALL_DIR}/traefik-ingress/values.yaml"
    kubectl -n traefik rollout status deploy/traefik --timeout=180s

    log "Applying infra and app manifests"
    kubectl apply -f "${INSTALL_DIR}/infrastructure/gateway.yaml"
    kubectl apply -f "${INSTALL_DIR}/apps/whoami/deployement.yaml"
    kubectl apply -f "${INSTALL_DIR}/apps/whoami/http-route.yaml"

    if [[ -f "${INSTALL_DIR}/apps/traefik-dashboard/auth" ]]; then
      kubectl -n traefik create secret generic traefik-dashboard-auth \
        --from-file=users="${INSTALL_DIR}/apps/traefik-dashboard/auth" \
        --dry-run=client -o yaml | kubectl apply -f -
      kubectl apply -f "${INSTALL_DIR}/apps/traefik-dashboard/dashboard-middlewares.yaml"
      kubectl apply -f "${INSTALL_DIR}/apps/traefik-dashboard/dashbaord-routes-ingress.yaml"
      kubectl apply -f "${INSTALL_DIR}/apps/traefik-dashboard/metrics-routes.yaml"
    fi

    if [[ "${INSTALL_NGINX}" == "true" ]]; then
      log "Linking nginx reverse proxy config from repo"
      NGINX_SOURCE_CONFIG="${INSTALL_DIR}/infrastructure/nginx/kubequest.conf"
      NGINX_TARGET_CONFIG="/etc/nginx/conf.d/kubequest.conf"

      if [[ ! -f "${NGINX_SOURCE_CONFIG}" ]]; then
        echo "Missing nginx source config: ${NGINX_SOURCE_CONFIG}"
        exit 1
      fi

      ln -sfn "${NGINX_SOURCE_CONFIG}" "${NGINX_TARGET_CONFIG}"
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
