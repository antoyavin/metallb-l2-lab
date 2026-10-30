#!/usr/bin/env bash
# Installe k3s, Helm et MetalLB, puis applique les manifests du lab.
# À lancer dans la VM, avec l'utilisateur ubuntu. Peut être relancé sans risque.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$(cd "$SCRIPT_DIR/../manifests" && pwd)"
ROLLOUT_TIMEOUT=300s

export KUBECONFIG="$HOME/.kube/config"

log() {
  printf '\n==> %s\n' "$*"
}

# retry <tentatives> <commande...> : réessaie toutes les 5 secondes.
retry() {
  local attempts=$1
  shift
  for ((i = 1; i <= attempts; i++)); do
    "$@" && return 0
    sleep 5
  done
  return 1
}

install_k3s() {
  if grep -qs servicelb /etc/systemd/system/k3s.service; then
    log "k3s déjà installé avec servicelb désactivé"
  else
    # Relancer l'installeur corrige aussi un k3s installé sans cette option.
    log "Installation de k3s sans servicelb"
    curl -sfL https://get.k3s.io | sh -s - --disable servicelb
  fi

  mkdir -p "$HOME/.kube"
  sudo install -m 600 -o "$(id -u)" -g "$(id -g)" /etc/rancher/k3s/k3s.yaml "$KUBECONFIG"

  log "Attente du nœud"
  retry 36 kubectl wait --for=condition=Ready node --all --timeout=5s 2>/dev/null
}

install_helm() {
  if command -v helm >/dev/null; then
    log "Helm déjà installé"
  else
    log "Installation de Helm"
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  fi
}

install_metallb() {
  log "Installation de MetalLB"
  helm repo add metallb https://metallb.github.io/metallb --force-update
  helm repo update metallb
  helm upgrade --install metallb metallb/metallb \
    --namespace metallb-system --create-namespace

  log "Attente des pods MetalLB"
  kubectl -n metallb-system rollout status deployment/metallb-controller --timeout="$ROLLOUT_TIMEOUT"
  kubectl -n metallb-system rollout status daemonset/metallb-speaker --timeout="$ROLLOUT_TIMEOUT"
}

traefik_has_ip() {
  [[ -n "$(kubectl -n kube-system get svc traefik \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)" ]]
}

apply_manifests() {
  # Le webhook de MetalLB peut refuser les requêtes juste après le démarrage.
  log "Application du pool d'adresses"
  retry 24 kubectl apply -f "$MANIFESTS_DIR/metallb-pool.yaml"

  # Traefik passe avant nginx pour obtenir la même répartition que dans le lab.
  log "Attente de l'IP de Traefik"
  retry 36 traefik_has_ip || log "Traefik n'a pas d'IP, on continue"

  log "Déploiement de nginx"
  kubectl apply -f "$MANIFESTS_DIR/nginx.yaml"
  kubectl rollout status deployment/nginx --timeout="$ROLLOUT_TIMEOUT"
}

install_k3s
install_helm
install_metallb
apply_manifests

log "Services LoadBalancer"
kubectl get svc -A | grep -E 'NAMESPACE|LoadBalancer'
