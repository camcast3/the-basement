#!/usr/bin/env bash
# setup-k8s-tools.sh — Install K8s management tools for The Basement Homelab
#
# Installs kubectl, helm, omnictl, hubble, and cilium CLI to ~/.local/bin.
# No root/sudo required. Idempotent — safe to re-run.
#
# Usage:
#   curl -sL <raw-url> | bash
#   # or
#   ./scripts/setup-k8s-tools.sh
#
# Optional: pass --with-kubeconfig to also pull kubeconfig from the Omni VM.
#   ./scripts/setup-k8s-tools.sh --with-kubeconfig

set -euo pipefail

# --- Configuration (update versions here) -----------------------------------
KUBECTL_VERSION="v1.33.0"
HELM_VERSION="v3.20.2"
OMNICTL_VERSION="v1.6.5"
HUBBLE_VERSION="v1.18.6"
CILIUM_CLI_VERSION="v0.18.3"

OMNI_VM="cameron@192.168.86.10"
OMNI_DOMAIN="omni.local.negativezone.cc"
# -----------------------------------------------------------------------------

BIN_DIR="${HOME}/.local/bin"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64)  ARCH="amd64" ;;
  aarch64) ARCH="arm64" ;;
  *)       echo "Unsupported architecture: ${ARCH}"; exit 1 ;;
esac

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"

info()  { echo -e "\033[1;34m==>\033[0m $*"; }
ok()    { echo -e "\033[1;32m ✓\033[0m  $*"; }
warn()  { echo -e "\033[1;33m !\033[0m  $*"; }

check_version() {
  local tool="$1" expected="$2" current="$3"
  if [[ "${current}" == *"${expected}"* ]]; then
    ok "${tool} ${expected} (already installed)"
    return 0
  fi
  return 1
}

mkdir -p "${BIN_DIR}"

# Ensure ~/.local/bin is in PATH
if [[ ":${PATH}:" != *":${BIN_DIR}:"* ]]; then
  export PATH="${BIN_DIR}:${PATH}"
fi

# Persist PATH in shell rc files
for rc in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
  if [[ -f "${rc}" ]] && ! grep -q '\.local/bin' "${rc}" 2>/dev/null; then
    echo 'export PATH="${HOME}/.local/bin:${PATH}"' >> "${rc}"
  fi
done

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║   The Basement — K8s Tools Setup             ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# --- kubectl -----------------------------------------------------------------
info "kubectl ${KUBECTL_VERSION}"
if command -v kubectl &>/dev/null && check_version kubectl "${KUBECTL_VERSION}" "$(kubectl version --client 2>&1)"; then
  :
else
  curl -sLo "${TMP_DIR}/kubectl" \
    "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${OS}/${ARCH}/kubectl"
  install -m 0755 "${TMP_DIR}/kubectl" "${BIN_DIR}/kubectl"
  ok "kubectl ${KUBECTL_VERSION} installed"
fi

# --- helm --------------------------------------------------------------------
info "Helm ${HELM_VERSION}"
if command -v helm &>/dev/null && check_version helm "${HELM_VERSION}" "$(helm version --short 2>&1)"; then
  :
else
  curl -sLo "${TMP_DIR}/helm.tar.gz" \
    "https://get.helm.sh/helm-${HELM_VERSION}-${OS}-${ARCH}.tar.gz"
  tar -xzf "${TMP_DIR}/helm.tar.gz" -C "${TMP_DIR}" "${OS}-${ARCH}/helm"
  install -m 0755 "${TMP_DIR}/${OS}-${ARCH}/helm" "${BIN_DIR}/helm"
  ok "Helm ${HELM_VERSION} installed"
fi

# --- omnictl -----------------------------------------------------------------
info "omnictl ${OMNICTL_VERSION}"
if command -v omnictl &>/dev/null && check_version omnictl "${OMNICTL_VERSION}" "$(omnictl --version 2>&1)"; then
  :
else
  curl -sLo "${TMP_DIR}/omnictl" \
    "https://github.com/siderolabs/omni/releases/download/${OMNICTL_VERSION}/omnictl-${OS}-${ARCH}"
  install -m 0755 "${TMP_DIR}/omnictl" "${BIN_DIR}/omnictl"
  ok "omnictl ${OMNICTL_VERSION} installed"
fi

# --- hubble ------------------------------------------------------------------
info "Hubble CLI ${HUBBLE_VERSION}"
if command -v hubble &>/dev/null && check_version hubble "${HUBBLE_VERSION}" "$(hubble version 2>&1)"; then
  :
else
  curl -sLo "${TMP_DIR}/hubble.tar.gz" \
    "https://github.com/cilium/hubble/releases/download/${HUBBLE_VERSION}/hubble-${OS}-${ARCH}.tar.gz"
  tar -xzf "${TMP_DIR}/hubble.tar.gz" -C "${TMP_DIR}" hubble
  install -m 0755 "${TMP_DIR}/hubble" "${BIN_DIR}/hubble"
  ok "Hubble CLI ${HUBBLE_VERSION} installed"
fi

# --- cilium CLI --------------------------------------------------------------
info "Cilium CLI ${CILIUM_CLI_VERSION}"
if command -v cilium &>/dev/null && check_version cilium "${CILIUM_CLI_VERSION}" "$(cilium version --client 2>&1)"; then
  :
else
  curl -sLo "${TMP_DIR}/cilium.tar.gz" \
    "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-${OS}-${ARCH}.tar.gz"
  tar -xzf "${TMP_DIR}/cilium.tar.gz" -C "${TMP_DIR}" cilium
  install -m 0755 "${TMP_DIR}/cilium" "${BIN_DIR}/cilium"
  ok "Cilium CLI ${CILIUM_CLI_VERSION} installed"
fi

# --- Helm repos --------------------------------------------------------------
info "Helm repositories"
helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true
helm repo update cilium &>/dev/null
ok "cilium repo ready"

# --- kubeconfig (optional) ---------------------------------------------------
if [[ "${1:-}" == "--with-kubeconfig" ]]; then
  info "Fetching kubeconfig from Omni VM (${OMNI_VM})"
  mkdir -p "${HOME}/.kube"
  if scp -o ConnectTimeout=5 "${OMNI_VM}:~/.kube/config" "${HOME}/.kube/config" 2>/dev/null; then
    ok "kubeconfig saved to ~/.kube/config"
  else
    warn "Could not reach ${OMNI_VM} — copy manually:"
    echo "    scp ${OMNI_VM}:~/.kube/config ~/.kube/config"
  fi
fi

# --- Summary -----------------------------------------------------------------
echo ""
echo "┌──────────────────────────────────────────────┐"
echo "│  Installed Tools                             │"
echo "├──────────┬───────────────────────────────────┤"
printf "│ kubectl  │ %-33s │\n" "$(kubectl version --client 2>&1 | grep -oP 'v[\d.]+' | head -1)"
printf "│ helm     │ %-33s │\n" "$(helm version --short 2>&1)"
printf "│ omnictl  │ %-33s │\n" "$(omnictl --version 2>&1 | awk '{print $3}')"
printf "│ hubble   │ %-33s │\n" "$(hubble version 2>&1 | awk '{print $2}')"
printf "│ cilium   │ %-33s │\n" "$(cilium version --client 2>&1 | awk '/cilium-cli:/{print $2}')"
echo "├──────────┴───────────────────────────────────┤"
echo "│  Path: ~/.local/bin                          │"
echo "└──────────────────────────────────────────────┘"
echo ""

if [[ ! -f "${HOME}/.kube/config" ]]; then
  echo "Next: pull your kubeconfig"
  echo "  scp ${OMNI_VM}:~/.kube/config ~/.kube/config"
  echo ""
fi
