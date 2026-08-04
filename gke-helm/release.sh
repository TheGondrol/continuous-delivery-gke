#!/usr/bin/env bash
# =============================================================================
# release.sh - Deploy ke GKE langsung lewat kubectl + helm (tanpa Cloud Deploy).
# -----------------------------------------------------------------------------
# Berbeda dari release.sh di gke-clouddeploy/: TIDAK mirror image ke Artifact
# Registry, dan TIDAK menarik secret aplikasi dari Vault. Image harus sudah
# ada di registry, dan Secret aplikasi (bila dipakai) dianggap sudah ada di
# cluster.
#
# Satu pengecualian: pull LANGSUNG dari Nexus didukung lewat Vault, sama pola
# dengan fase 1 gke-clouddeploy/release.sh. Isi VAULT_NEXUS_PATH di .env untuk
# mengaktifkan — release.sh akan membuat/refresh Secret docker-registry di
# namespace tujuan dari kredensial Vault, dan memasangnya otomatis ke pod.
# Lihat README bagian 'Pull langsung dari Nexus' untuk syarat jaringan & TLS
# yang di luar kendali skrip ini.
#
# Pakai:
#   cp .env.example .env    # sekali, lalu isi cluster tujuan
#   ./release.sh <app-name> <image[:tag]> [values-file] [-- extra-helm-args...]
#
# Contoh:
#   ./release.sh iris-classifier asia-southeast2-docker.pkg.dev/proj/repo/iris-classifier:v1.2.0
#   ./release.sh iris-classifier .../iris-classifier:v1.2.0 values-staging.yaml
#   ./release.sh iris-classifier .../iris-classifier:v1.2.0 -- --set appPort=8080
#   # Pull langsung dari Nexus, kredensial dari Vault (VAULT_NEXUS_PATH di .env):
#   ./release.sh iris-classifier new-nexus.gcp.bri.co.id/bribrain/dev/iris-classifier:latest
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

# Pull langsung dari Nexus lewat Vault aktif hanya bila VAULT_NEXUS_PATH diisi.
NEXUS_PULL_MODE=0
if [[ -n "${VAULT_NEXUS_PATH:-}" ]]; then
  NEXUS_PULL_MODE=1
  require NEXUS_HOST VAULT_ADDR
fi

# Channel ini TIDAK mirror image (lihat header) — deteksi kesalahan paling
# umum SEDINI mungkin: argumen image menunjuk ke registry yang node GKE tidak
# bisa auto-autentikasi ke sana, bukan ke Artifact Registry/GCR maupun Nexus
# yang sudah dikonfigurasi lewat VAULT_NEXUS_PATH. Tanpa ini, kesalahannya
# baru ketahuan setelah rollout ImagePullBackOff timeout beberapa menit
# kemudian.
case "$IMAGE_REPO" in
  *.pkg.dev/*|*gcr.io/*)
    ;;
  "${NEXUS_HOST:-__nexus_host_kosong__}"/*)
    if [[ "$NEXUS_PULL_MODE" -eq 0 && -z "${ALLOW_ANY_REGISTRY:-}" ]]; then
      echo "!! Image '$IMAGE_REPO' dari NEXUS_HOST, tapi VAULT_NEXUS_PATH kosong di $ENV_FILE." >&2
      echo "   Tanpa itu tidak ada Secret pull yang dibuat, node GKE tidak punya kredensial" >&2
      echo "   Nexus dan pull akan gagal ImagePullBackOff. Isi VAULT_NEXUS_PATH (lihat" >&2
      echo "   README bagian 'Pull langsung dari Nexus'), atau bila Secret pull sudah kamu" >&2
      echo "   siapkan manual: ALLOW_ANY_REGISTRY=1 ./release.sh ... -- --set imagePullSecretName=<nama>" >&2
      exit 1
    fi
    ;;
  *)
    if [[ -z "${ALLOW_ANY_REGISTRY:-}" ]]; then
      echo "!! Image '$IMAGE_REPO' bukan Artifact Registry/GCR (*.pkg.dev atau *gcr.io)." >&2
      echo "   Node GKE cuma auto-autentikasi ke registry Google — pull dari host lain" >&2
      echo "   akan gagal ImagePullBackOff kecuali chart sudah dikonfigurasi" >&2
      echo "   imagePullSecretName untuk registry itu." >&2
      echo "" >&2
      echo "   Opsi A - mirror ke Artifact Registry (tidak perlu Secret pull di cluster):" >&2
      echo "     gcloud auth print-access-token | crane auth login <AR_HOST> -u oauth2accesstoken --password-stdin" >&2
      echo "     crane copy $IMAGE_REPO:$IMAGE_TAG <AR_HOST>/<AR_PROJECT>/<AR_REPO>/${APP_NAME}:${IMAGE_TAG}" >&2
      echo "     lalu jalankan ulang dengan path Artifact Registry-nya." >&2
      echo "" >&2
      echo "   Opsi B - pull langsung dari registry ini: buat Secret docker-registry di" >&2
      echo "     namespace tujuan, isi values.imagePullSecretName ke nama Secret itu, lalu" >&2
      echo "     jalankan ulang dengan ALLOW_ANY_REGISTRY=1. Detail: README bagian 'Pull" >&2
      echo "     langsung dari Nexus'." >&2
      exit 1
    fi
    ;;
esac

# ---------- Prasyarat perkakas ----------
# Saran pemasangan disesuaikan OS — skrip tidak meng-install apa pun secara
# otomatis, hanya mencetak perintahnya (konsisten dengan gke-clouddeploy/release.sh).
MISSING=""
for t in kubectl helm gcloud gke-gcloud-auth-plugin; do
  command -v "$t" >/dev/null 2>&1 || MISSING="$MISSING $t"
done
if [[ "$NEXUS_PULL_MODE" -eq 1 ]]; then
  for t in curl jq; do
    command -v "$t" >/dev/null 2>&1 || MISSING="$MISSING $t"
  done
fi
if [[ -n "$MISSING" ]]; then
  echo "!! Perkakas belum terpasang:$MISSING" >&2
  for t in $MISSING; do
    if [[ "$(uname -s)" == "Darwin" ]]; then
      case "$t" in
        kubectl)                 echo "   kubectl: brew install kubectl" >&2 ;;
        helm)                    echo "   helm   : brew install helm" >&2 ;;
        gcloud)                  echo "   gcloud : brew install --cask gcloud-cli" >&2 ;;
        gke-gcloud-auth-plugin)  echo "   gke-gcloud-auth-plugin: gcloud components install gke-gcloud-auth-plugin" >&2 ;;
        jq)                      echo "   jq     : brew install jq" >&2 ;;
        curl)                    echo "   curl   : bawaan OS - periksa PATH" >&2 ;;
      esac
    else
      # Runner sesungguhnya (GCE) sering punya gcloud terpasang lewat SNAP
      # (bukan apt, bukan installer interaktif) — di situ baik `apt-get
      # install google-cloud-*` maupun `gcloud components install` DITOLAK
      # ("managed by an external package manager"), dan tidak ada snap
      # terpisah untuk gke-gcloud-auth-plugin. Saran di bawah karena itu
      # memakai cara yang tidak bergantung pada bagaimana gcloud terpasang:
      # unduh binary resmi langsung (kubectl) dan tarik plugin dari tarball
      # terpisah tanpa mengganggu gcloud yang sedang dipakai untuk auth.
      case "$t" in
        kubectl)
          echo "   kubectl: unduh binary resmi (tidak bergantung cara gcloud terpasang):" >&2
          echo "     curl -LO \"https://dl.k8s.io/release/\$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl\"" >&2
          echo "     sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl" >&2
          ;;
        helm)
          echo "   helm   : curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash" >&2
          ;;
        gcloud)
          echo "   gcloud : https://cloud.google.com/sdk/docs/install" >&2
          ;;
        gke-gcloud-auth-plugin)
          echo "   gke-gcloud-auth-plugin: gcloud snap TIDAK bisa 'components install'. Tarik dari" >&2
          echo "     installer tarball terpisah, tanpa mengganggu gcloud yang aktif:" >&2
          echo "       curl -O https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz" >&2
          echo "       tar -xf google-cloud-cli-linux-x86_64.tar.gz -C \"\$HOME\"" >&2
          echo "       \"\$HOME/google-cloud-sdk/install.sh\" --quiet --path-update false --command-completion false" >&2
          echo "       sudo ln -sf \"\$HOME/google-cloud-sdk/bin/gke-gcloud-auth-plugin\" /usr/local/bin/gke-gcloud-auth-plugin" >&2
          echo "     Bila gcloud di runner ini terpasang lewat apt (bukan snap), cukup:" >&2
          echo "       sudo apt-get install -y google-cloud-cli-gke-gcloud-auth-plugin" >&2
          ;;
        jq)   echo "   jq     : sudo apt-get install -y jq   # atau: dnf install jq" >&2 ;;
        curl) echo "   curl   : sudo apt-get install -y curl" >&2 ;;
      esac
    fi
  done
  echo "   Detail : README bagian 'Prasyarat'" >&2
  exit 1
fi

# Vault opsional, tapi bila diaktifkan cek prasyaratnya SEKARANG — jangan
# sampai gagal setelah kredensial cluster sudah terlanjur diambil.
if [[ "$NEXUS_PULL_MODE" -eq 1 ]]; then
  [[ -n "${VAULT_TOKEN:-}" ]] || {
    echo "!! VAULT_NEXUS_PATH diisi tapi VAULT_TOKEN kosong." >&2
    echo "   Set lewat env var dari CI (bukan .env): export VAULT_TOKEN=..." >&2
    exit 1
  }
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
if [[ "$NEXUS_PULL_MODE" -eq 1 ]]; then
  echo " Pull Nexus : ${VAULT_ADDR%/}/v1/${VAULT_NEXUS_PATH} (Vault) -> Secret ${APP_NAME}-nexus-pull"
else
  echo " Pull Nexus : (nonaktif - VAULT_NEXUS_PATH kosong)"
fi
if [[ -n "$IMPERSONATE_SA" ]]; then
  echo " Identitas  : $IMPERSONATE_SA (impersonasi)"
else
  echo " Identitas  : $(gcloud config get-value account 2>/dev/null || echo '?')"
fi
echo "=============================================================="

# ---------- Kredensial cluster ----------
echo ">> [1/3] Mengambil kredensial cluster..."
gcloud container clusters get-credentials "$CLUSTER" \
  --region="$REGION" --project="$PROJECT" $GCLOUD_IMP

# Namespace harus ada SEBELUM Secret pull dibuat di dalamnya. `helm
# --create-namespace` juga membuatnya, tapi itu baru jalan di fase helm —
# terlambat untuk langkah Vault di bawah.
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# ---------- Pull Secret dari Nexus (opsional, lewat Vault) ----------
NEXUS_PULL_SECRET=""
if [[ "$NEXUS_PULL_MODE" -eq 1 ]]; then
  echo ">> [2/3] Menyiapkan Secret pull Nexus dari Vault..."
  VAULT_NEXUS_USER_KEY="${VAULT_NEXUS_USER_KEY:-NEXUS_USER}"
  VAULT_NEXUS_PASS_KEY="${VAULT_NEXUS_PASS_KEY:-NEXUS_PASS}"

  echo "   Kredensial Nexus dari Vault: /v1/${VAULT_NEXUS_PATH}"
  NEXUS_JSON="$(curl -fsS -H "X-Vault-Token: ${VAULT_TOKEN}" "${VAULT_ADDR%/}/v1/${VAULT_NEXUS_PATH}")" || {
    echo "!! Gagal membaca ${VAULT_ADDR%/}/v1/${VAULT_NEXUS_PATH}" >&2
    echo "   Cek token masih valid, path benar, dan runner bisa menjangkau Vault." >&2
    exit 1
  }
  NEXUS_USER="$(jq -r --arg k "$VAULT_NEXUS_USER_KEY" '.data.data[$k] // empty' <<<"$NEXUS_JSON")"
  NEXUS_PASS="$(jq -r --arg k "$VAULT_NEXUS_PASS_KEY" '.data.data[$k] // empty' <<<"$NEXUS_JSON")"
  AVAIL="$(jq -r '(.data.data // {}) | keys_unsorted | join(", ")' <<<"$NEXUS_JSON")"
  unset NEXUS_JSON
  [[ -n "$NEXUS_USER" && -n "$NEXUS_PASS" ]] || {
    echo "!! Key '$VAULT_NEXUS_USER_KEY' / '$VAULT_NEXUS_PASS_KEY' tidak lengkap di path itu." >&2
    echo "   Key yang tersedia di sana: $AVAIL" >&2
    echo "   Sesuaikan VAULT_NEXUS_USER_KEY / VAULT_NEXUS_PASS_KEY di $ENV_FILE." >&2
    exit 1
  }
  echo "   OK - login sebagai '$NEXUS_USER'"

  NEXUS_PULL_SECRET="${APP_NAME}-nexus-pull"
  # --dry-run=client -o yaml | apply: idempoten, aman dipanggil ulang tiap
  # rilis (create-or-update), tidak gagal dengan "already exists".
  kubectl create secret docker-registry "$NEXUS_PULL_SECRET" \
    --docker-server="$NEXUS_HOST" \
    --docker-username="$NEXUS_USER" \
    --docker-password="$NEXUS_PASS" \
    -n "$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  unset NEXUS_USER NEXUS_PASS
  echo "   OK - Secret '$NEXUS_PULL_SECRET' diperbarui di namespace $NAMESPACE"
else
  echo ">> [2/3] Pull Secret Nexus dilewati (VAULT_NEXUS_PATH kosong)."
fi

# ---------- Helm upgrade/install ----------
echo ">> [3/3] helm upgrade --install..."
HELM_ARGS=(
  upgrade --install "$APP_NAME" "$CHART_DIR"
  --namespace "$NAMESPACE" --create-namespace
  --set "appName=$APP_NAME"
  --set "image.repository=$IMAGE_REPO"
  --set "image.tag=$IMAGE_TAG"
)
[[ -n "$VALUES_FILE" ]] && HELM_ARGS+=(-f "$VALUES_FILE")
# Ditaruh SEBELUM extra args: kalau user mengirim --set imagePullSecretName=...
# sendiri lewat argumen `--`, itu tetap menang (helm pakai nilai --set terakhir).
[[ -n "$NEXUS_PULL_SECRET" ]] && HELM_ARGS+=(--set "imagePullSecretName=$NEXUS_PULL_SECRET")
HELM_ARGS+=("${EXTRA_HELM_ARGS[@]}")

helm "${HELM_ARGS[@]}"

echo ">> Menunggu rollout..."
kubectl rollout status "deployment/$APP_NAME" -n "$NAMESPACE" --timeout=180s

echo ""
echo ">> Selesai. Status resource:"
kubectl get deploy,svc,hpa,ingress -n "$NAMESPACE" -l "app=$APP_NAME"
