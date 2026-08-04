#!/usr/bin/env bash
# =============================================================================
# release.sh - Deploy ke GKE langsung lewat kubectl + helm (tanpa Cloud Deploy).
# -----------------------------------------------------------------------------
# Berbeda dari release.sh di gke-clouddeploy/: TIDAK ada mirror Nexus->Artifact
# Registry dan TIDAK menarik secret dari Vault. Image harus sudah ada di
# registry, dan Secret aplikasi (bila dipakai) dianggap sudah ada di cluster.
#
# Pakai:
#   cp .env.example .env    # sekali, lalu isi cluster tujuan
#   ./release.sh <app-name> <image[:tag]> [values-file] [-- extra-helm-args...]
#
# Contoh:
#   ./release.sh iris-classifier asia-southeast2-docker.pkg.dev/proj/repo/iris-classifier:v1.2.0
#   ./release.sh iris-classifier .../iris-classifier:v1.2.0 values-staging.yaml
#   ./release.sh iris-classifier .../iris-classifier:v1.2.0 -- --set appPort=8080
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$SCRIPT_DIR/chart"

# ---------- Argumen ----------
APP_NAME="${1:?Usage: ./release.sh <app-name> <image[:tag]> [values-file] [-- extra-helm-args...]}"
IMAGE="${2:?Usage: ./release.sh <app-name> <image[:tag]> [values-file] [-- extra-helm-args...]}"
shift 2

VALUES_FILE=""
if [[ $# -gt 0 && "$1" != "--" ]]; then
  VALUES_FILE="$1"
  shift
fi
[[ $# -gt 0 && "$1" == "--" ]] && shift
EXTRA_HELM_ARGS=("$@")

# repository:tag -> pisahkan pada ':' terakhir SETELAH '/' terakhir, supaya
# host berformat host:port (tanpa tag) tidak salah terpotong.
IMAGE_REPO="${IMAGE%:*}"
IMAGE_TAG="${IMAGE##*:}"
if [[ "$IMAGE_TAG" == */* ]]; then
  IMAGE_REPO="$IMAGE"
  IMAGE_TAG="latest"
fi

# ---------- Muat .env ----------
# Env var yang sudah di-set di shell menang atas nilai di .env.
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
if [[ -f "$ENV_FILE" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"; key="${key//[[:space:]]/}"
    val="${line#*=}"
    val="${val%$'\r'}"                        # tahan file bergaya CRLF
    val="${val#\"}"; val="${val%\"}"          # buang tanda kutip pembungkus
    val="${val#\'}"; val="${val%\'}"
    [[ -n "${!key:-}" ]] && continue          # env var dari shell menang
    export "$key=$val"
  done < "$ENV_FILE"
else
  echo "!! $ENV_FILE tidak ditemukan. Jalankan: cp .env.example .env" >&2
  exit 1
fi

require() {
  local n
  for n in "$@"; do
    [[ -n "${!n:-}" ]] || { echo "!! $n belum diisi di $ENV_FILE" >&2; exit 1; }
  done
}
require REGION PROJECT CLUSTER NAMESPACE

# ---------- Prasyarat perkakas ----------
MISSING=""
for t in kubectl helm gcloud; do
  command -v "$t" >/dev/null 2>&1 || MISSING="$MISSING $t"
done
if [[ -n "$MISSING" ]]; then
  echo "!! Perkakas belum terpasang:$MISSING" >&2
  echo "   kubectl : https://kubernetes.io/docs/tasks/tools/" >&2
  echo "   helm    : https://helm.sh/docs/intro/install/" >&2
  echo "   gcloud  : https://cloud.google.com/sdk/docs/install" >&2
  exit 1
fi

# Impersonasi service account (opsional) — diterapkan ke pemanggilan gcloud
# yang mengambil kredensial cluster.
IMPERSONATE_SA="${IMPERSONATE_SA:-}"
GCLOUD_IMP=""
[[ -n "$IMPERSONATE_SA" ]] && GCLOUD_IMP="--impersonate-service-account=$IMPERSONATE_SA"

echo "=============================================================="
echo " App        : $APP_NAME"
echo " Image      : $IMAGE_REPO:$IMAGE_TAG"
echo " Cluster    : $CLUSTER / $PROJECT (region $REGION)"
echo " Namespace  : $NAMESPACE"
if [[ -n "$VALUES_FILE" ]]; then
  echo " Values     : $VALUES_FILE"
else
  echo " Values     : chart/values.yaml (default)"
fi
if [[ -n "$IMPERSONATE_SA" ]]; then
  echo " Identitas  : $IMPERSONATE_SA (impersonasi)"
else
  echo " Identitas  : $(gcloud config get-value account 2>/dev/null || echo '?')"
fi
echo "=============================================================="

# ---------- Kredensial cluster ----------
echo ">> [1/2] Mengambil kredensial cluster..."
gcloud container clusters get-credentials "$CLUSTER" \
  --region="$REGION" --project="$PROJECT" $GCLOUD_IMP

# ---------- Helm upgrade/install ----------
echo ">> [2/2] helm upgrade --install..."
HELM_ARGS=(
  upgrade --install "$APP_NAME" "$CHART_DIR"
  --namespace "$NAMESPACE" --create-namespace
  --set "appName=$APP_NAME"
  --set "image.repository=$IMAGE_REPO"
  --set "image.tag=$IMAGE_TAG"
)
[[ -n "$VALUES_FILE" ]] && HELM_ARGS+=(-f "$VALUES_FILE")
HELM_ARGS+=("${EXTRA_HELM_ARGS[@]}")

helm "${HELM_ARGS[@]}"

echo ">> Menunggu rollout..."
kubectl rollout status "deployment/$APP_NAME" -n "$NAMESPACE" --timeout=180s

echo ""
echo ">> Selesai. Status resource:"
kubectl get deploy,svc,hpa,ingress -n "$NAMESPACE" -l "app=$APP_NAME"
