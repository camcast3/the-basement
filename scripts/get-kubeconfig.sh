#!/usr/bin/env bash
# get-kubeconfig.sh — Fetch kubeconfig from Omni for The Basement K8s cluster
#
# Uses omnictl to pull a fresh kubeconfig from the Omni management plane.
# Safe to re-run anytime kubectl stops working (e.g., expired tokens).
#
# Usage:
#   ./scripts/get-kubeconfig.sh                      # defaults: cluster=k8s-homelab, output=~/.kube/config
#   ./scripts/get-kubeconfig.sh -c my-cluster        # specify cluster name
#   ./scripts/get-kubeconfig.sh -o ~/custom-config   # specify output path
#   ./scripts/get-kubeconfig.sh --force              # overwrite without prompting
#
# Environment variables (override defaults):
#   OMNI_URL          — Omni API URL (default: https://omni.local.negativezone.cc)
#   OMNI_CLUSTER      — Cluster name (default: k8s-homelab)
#   KUBECONFIG_OUTPUT — Output file path (default: ~/.kube/config)

set -euo pipefail

# --- Defaults ----------------------------------------------------------------
OMNI_URL="${OMNI_URL:-https://omni.local.negativezone.cc}"
CLUSTER="${OMNI_CLUSTER:-k8s-homelab}"
OUTPUT="${KUBECONFIG_OUTPUT:-${HOME}/.kube/config}"
FORCE=false

# --- Helpers -----------------------------------------------------------------
info()  { echo -e "\033[1;34m==>\033[0m $*"; }
ok()    { echo -e "\033[1;32m ✓\033[0m  $*"; }
err()   { echo -e "\033[1;31m ✗\033[0m  $*" >&2; }
die()   { err "$*"; exit 1; }

usage() {
  sed -n '2,/^$/s/^# //p' "$0"
  exit 0
}

# --- Parse args --------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--cluster) CLUSTER="$2"; shift 2 ;;
    -o|--output)  OUTPUT="$2"; shift 2 ;;
    -f|--force)   FORCE=true; shift ;;
    -h|--help)    usage ;;
    *)            die "Unknown option: $1" ;;
  esac
done

# --- Preflight checks --------------------------------------------------------
if ! command -v omnictl &>/dev/null; then
  die "omnictl not found. Install it with: ./scripts/setup-k8s-tools.sh"
fi

# --- Configure omnictl endpoint ----------------------------------------------
info "Omni endpoint: ${OMNI_URL}"
info "Cluster: ${CLUSTER}"

# Set the omni-url in omnictl config (idempotent)
omnictl config url "${OMNI_URL}" 2>/dev/null || \
  omnictl config set omni-url "${OMNI_URL}" 2>/dev/null || true

# --- Backup existing kubeconfig if present -----------------------------------
if [[ -f "${OUTPUT}" && "${FORCE}" != true ]]; then
  BACKUP="${OUTPUT}.bak.$(date +%Y%m%d%H%M%S)"
  cp "${OUTPUT}" "${BACKUP}"
  info "Backed up existing kubeconfig to ${BACKUP}"
fi

# --- Fetch kubeconfig --------------------------------------------------------
info "Fetching kubeconfig from Omni..."
mkdir -p "$(dirname "${OUTPUT}")"

if ! omnictl kubeconfig -c "${CLUSTER}" --force "${OUTPUT}" 2>/dev/null; then
  # Fallback: some omnictl versions use positional args or different flags
  if ! omnictl kubeconfig "${CLUSTER}" --force > "${OUTPUT}" 2>/dev/null; then
    if ! omnictl kubeconfig -c "${CLUSTER}" > "${OUTPUT}"; then
      die "Failed to fetch kubeconfig. Ensure you are authenticated with Omni."
    fi
  fi
fi

ok "Kubeconfig written to ${OUTPUT}"

# --- Set KUBECONFIG if not default path --------------------------------------
if [[ "${OUTPUT}" != "${HOME}/.kube/config" ]]; then
  echo ""
  info "Non-default path — export KUBECONFIG to use it:"
  echo "  export KUBECONFIG=${OUTPUT}"
fi

# --- Verify connectivity -----------------------------------------------------
info "Verifying cluster connectivity..."
if kubectl --kubeconfig="${OUTPUT}" get nodes --request-timeout=10s &>/dev/null; then
  ok "kubectl is working — cluster nodes reachable"
  echo ""
  kubectl --kubeconfig="${OUTPUT}" get nodes
else
  err "Could not reach cluster nodes. The kubeconfig was written but the cluster may be unreachable."
  echo "  Check: network connectivity, DNS for ${OMNI_URL}, and cluster health in Omni."
  exit 1
fi
