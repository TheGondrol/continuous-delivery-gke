#!/usr/bin/env bash
# =============================================================================
# release.sh - Rilis ke GKE: mirror image (Nexus -> Artifact Registry)
#              + tarik secret dari Vault + buat release Cloud Deploy.
# -----------------------------------------------------------------------------
# Pakai:
#   cp .env.example .env    # sekali, lalu isi
#   export VAULT_TOKEN=...  # dari secret variable CI, JANGAN taruh di .env
#   ./release.sh <app-name> [image-tag]
#
# Contoh:
#   ./release.sh iris-classifier v1.2.0
#   APP_PORT=8080 ./release.sh other-app latest    # timpa nilai .env sementara
#
# Prasyarat: setup sekali-jalan selesai (lihat README); `crane` & `gcloud` ada,
#            plus `curl` & `jq` bila Vault diaktifkan.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- Argumen ----------
APP_NAME="${1:?Usage: ./release.sh <app-name> [image-tag]}"
IMAGE_TAG="${2:-latest}"

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
require REGION APP_PORT TOOLING_PROJECT AR_HOST AR_REPO \
        NEXUS_HOST NEXUS_PATH DEV_PROJECT DEV_CLUSTER

# Vault opsional, tapi bila diaktifkan cek prasyaratnya SEKARANG — jangan sampai
# gagal setelah mirror image (fase 1) sudah terlanjur jalan.
if [[ -n "${VAULT_ADDR:-}" ]]; then
  [[ -n "${VAULT_TOKEN:-}" ]] || {
    echo "!! VAULT_ADDR diisi tapi VAULT_TOKEN kosong." >&2
    echo "   Set lewat env var dari CI (bukan .env): export VAULT_TOKEN=..." >&2
    exit 1
  }
  command -v jq >/dev/null || { echo "!! 'jq' dibutuhkan untuk membaca Vault." >&2; exit 1; }
elif [[ -n "${VAULT_NEXUS_PATH:-}" ]]; then
  echo "!! VAULT_NEXUS_PATH diisi tapi VAULT_ADDR kosong." >&2
  exit 1
fi

# Baca satu path Vault (KV v2) -> JSON ke stdout.
# Dipakai untuk kredensial Nexus (fase 1) maupun secret aplikasi (fase 2).
vault_read() {
  curl -fsS -H "X-Vault-Token: ${VAULT_TOKEN}" "${VAULT_ADDR%/}/v1/$1" || {
    echo "!! Gagal membaca ${VAULT_ADDR%/}/v1/$1" >&2
    echo "   Cek token masih valid, path benar, dan runner bisa menjangkau Vault." >&2
    return 1
  }
}

# ---------- Turunan ----------
SRC_IMAGE="${NEXUS_HOST}/${NEXUS_PATH}/${APP_NAME}:${IMAGE_TAG}"
DST_IMAGE="${AR_HOST}/${TOOLING_PROJECT}/${AR_REPO}/${APP_NAME}:${IMAGE_TAG}"
PIPELINE="${APP_NAME}-gke-pipeline"
RELEASE_NAME="rel-$(date +%Y%m%d-%H%M%S)"
SECRET_NAME="${APP_NAME}-secret"

# Vault opsional: aktif hanya bila VAULT_ADDR diisi.
# Path default mengikuti nama app; VAULT_SECRET_PATH menimpanya bila perlu
# (mis. beberapa app berbagi satu secret, atau nama di Vault berbeda).
VAULT_SECRET_PATH="${VAULT_SECRET_PATH:-${VAULT_MOUNT:-}/data/${VAULT_ENV:-}/${APP_NAME}}"

# Kredensial Nexus: infra bersama, bukan milik satu app — pathnya terpisah dari
# secret aplikasi dan harus diisi eksplisit. Kosong = pakai nilai dari .env.
VAULT_NEXUS_PATH="${VAULT_NEXUS_PATH:-}"
# Nama key di dalam secret Vault sengaja sama dengan nama variabel di .env,
# jadi default ini cocok tanpa konfigurasi tambahan.
VAULT_NEXUS_USER_KEY="${VAULT_NEXUS_USER_KEY:-NEXUS_USER}"
VAULT_NEXUS_PASS_KEY="${VAULT_NEXUS_PASS_KEY:-NEXUS_PASS}"

echo "=============================================================="
echo " App        : $APP_NAME:$IMAGE_TAG   (channel: GKE)"
echo " Mirror     : $SRC_IMAGE"
echo "           -> $DST_IMAGE"
echo " Pipeline   : $PIPELINE  (region $REGION, project $TOOLING_PROJECT)"
echo " Target dev : $DEV_PROJECT / $DEV_CLUSTER"
if [[ -n "${VAULT_ADDR:-}" ]]; then
  echo " Vault app  : ${VAULT_ADDR%/}/v1/${VAULT_SECRET_PATH}"
else
  echo " Vault app  : (nonaktif - VAULT_ADDR kosong)"
fi
if [[ -n "$VAULT_NEXUS_PATH" ]]; then
  echo " Vault nexus: ${VAULT_ADDR%/}/v1/${VAULT_NEXUS_PATH}"
else
  echo " Vault nexus: (nonaktif - kredensial Nexus dari $ENV_FILE)"
fi
echo " Release    : $RELEASE_NAME"
echo "=============================================================="

# ---------- FASE 1: Mirror Nexus -> Artifact Registry ----------
echo ">> [1/3] Mirror image ke Artifact Registry..."

# Kredensial Nexus dari Vault. Ini menimpa NEXUS_USER/NEXUS_PASS dari .env —
# bila VAULT_NEXUS_PATH diisi, Vault-lah sumber kebenarannya.
if [[ -n "$VAULT_NEXUS_PATH" ]]; then
  echo "   Kredensial Nexus dari Vault: /v1/${VAULT_NEXUS_PATH}"
  NEXUS_JSON="$(vault_read "$VAULT_NEXUS_PATH")"
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
fi

if [[ -n "${NEXUS_USER:-}" && -n "${NEXUS_PASS:-}" ]]; then
  # --password-stdin: password tidak pernah tampil di daftar proses (`ps`),
  # yang akan terjadi bila dilewatkan sebagai argumen `-p`.
  printf '%s' "$NEXUS_PASS" \
    | crane auth login "$NEXUS_HOST" -u "$NEXUS_USER" --password-stdin
fi
unset NEXUS_PASS

crane copy "$SRC_IMAGE" "$DST_IMAGE"

# ---------- FASE 2: Render template ----------
echo ">> [2/3] Merender manifest ke workdir sementara..."
WORKDIR="$(mktemp -d)"
chmod 700 "$WORKDIR"                        # workdir memuat secret; batasi akses
trap 'rm -rf "$WORKDIR"' EXIT

cp "$SCRIPT_DIR/clouddeploy.yaml" "$SCRIPT_DIR/skaffold.yaml" "$WORKDIR/"
cp -r "$SCRIPT_DIR/manifests" "$WORKDIR/"

# Substitusi placeholder. `sed -i.bak` supaya jalan di GNU sed & BSD/macOS sed.
while IFS= read -r -d '' f; do
  sed -i.bak \
    -e "s|APP_NAME|${APP_NAME}|g" \
    -e "s|APP_PORT|${APP_PORT}|g" \
    -e "s|REGION|${REGION}|g" \
    -e "s|DEV_PROJECT|${DEV_PROJECT}|g" \
    -e "s|DEV_CLUSTER|${DEV_CLUSTER}|g" \
    -e "s|STAGING_PROJECT|${STAGING_PROJECT:-}|g" \
    -e "s|STAGING_CLUSTER|${STAGING_CLUSTER:-}|g" \
    -e "s|PROD_PROJECT|${PROD_PROJECT:-}|g" \
    -e "s|PROD_CLUSTER|${PROD_CLUSTER:-}|g" \
    "$f"
  rm -f "$f.bak"
done < <(find "$WORKDIR" -type f -name '*.yaml' -print0)

# ---------- Secret dari Vault ----------
# Dirender SETELAH loop sed di atas: nilai secret tidak boleh ikut tersubstitusi
# (mis. sebuah token yang kebetulan memuat string "REGION" akan rusak).
#
# secret.yaml selalu dirender supaya `envFrom.secretRef` di deployment.yaml
# selalu punya sasaran. Bila Vault nonaktif, isinya kosong.
SECRET_FILE="$WORKDIR/manifests/secret.yaml"
SECRET_BODY=""

# Key yang TIDAK boleh ikut ke pod. Kredensial Nexus selalu dikecualikan: itu
# milik runner, bukan aplikasi — dan di layout Vault kami ia bisa berada di path
# yang sama dengan secret aplikasi. Tanpa saringan ini, kredensial registry akan
# bocor jadi env var di pod sekaligus tersimpan di bucket render Cloud Deploy.
EXCLUDE_KEYS=("$VAULT_NEXUS_USER_KEY" "$VAULT_NEXUS_PASS_KEY")
if [[ -n "${VAULT_SECRET_EXCLUDE_KEYS:-}" ]]; then
  IFS=',' read -ra _extra <<<"$VAULT_SECRET_EXCLUDE_KEYS"
  for _k in "${_extra[@]}"; do
    _k="${_k//[[:space:]]/}"
    [[ -n "$_k" ]] && EXCLUDE_KEYS+=("$_k")
  done
fi

if [[ -n "${VAULT_ADDR:-}" ]]; then
  echo "   Mengambil secret dari Vault: /v1/${VAULT_SECRET_PATH}"

  # KV v2 -> nilai ada di .data.data (bukan .data).
  VAULT_JSON="$(vault_read "$VAULT_SECRET_PATH")"

  # Dibangun lewat jq supaya nama key dengan karakter aneh tetap aman.
  EXCLUDE_JSON="$(printf '%s\n' "${EXCLUDE_KEYS[@]}" | jq -R . | jq -sc .)"

  # Nilai dikutip lewat @json: string JSON adalah skalar YAML yang sah, jadi
  # karakter seperti : # " \n di dalam secret tidak merusak manifest.
  SECRET_BODY="$(jq -r --argjson ex "$EXCLUDE_JSON" '
      (.data.data // {})
      | with_entries(select(.key as $k | $ex | index($k) | not))
      | to_entries[]
      | "  \(.key): \(.value | tostring | @json)"
    ' <<<"$VAULT_JSON")"

  # Hanya nama key yang dicetak — nilainya tidak pernah masuk log.
  KEPT="$(jq -r --argjson ex "$EXCLUDE_JSON" '
      (.data.data // {}) | keys_unsorted - $ex | join(", ")' <<<"$VAULT_JSON")"
  DROPPED="$(jq -r --argjson ex "$EXCLUDE_JSON" '
      [(.data.data // {}) | keys_unsorted[] | select(. as $k | $ex | index($k))] | join(", ")' <<<"$VAULT_JSON")"
  VERSION="$(jq -r '.data.metadata.version // "?"' <<<"$VAULT_JSON")"

  if [[ -z "$SECRET_BODY" ]]; then
    echo "   !! Tidak ada key yang layak dikirim ke pod (versi $VERSION). Secret dirender kosong." >&2
  else
    echo "   OK - versi $VERSION, key ke pod: $KEPT"
  fi
  # Selalu laporkan apa yang disaring — jangan pernah diam-diam membuang.
  [[ -n "$DROPPED" ]] && echo "   Dikecualikan (kredensial runner, tidak ke pod): $DROPPED"
  unset VAULT_JSON
else
  echo "   Vault nonaktif (VAULT_ADDR kosong) - Secret dirender kosong."
fi

umask 077
cat > "$SECRET_FILE" <<EOF
# Dihasilkan oleh release.sh dari Vault - JANGAN commit, JANGAN edit manual.
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  labels:
    app: ${APP_NAME}
type: Opaque
EOF
if [[ -z "$SECRET_BODY" ]]; then
  printf 'stringData: {}\n' >> "$SECRET_FILE"
else
  printf 'stringData:\n%s\n' "$SECRET_BODY" >> "$SECRET_FILE"
fi
unset SECRET_BODY

# ---------- FASE 3: Daftarkan pipeline & buat release ----------
echo ">> [3/3] Membuat release Cloud Deploy..."

# Daftarkan/refresh pipeline & target
gcloud deploy apply \
  --file="$WORKDIR/clouddeploy.yaml" \
  --region="$REGION" \
  --project="$TOOLING_PROJECT"

# Buat release; image aktual diinjeksikan lewat --images
gcloud deploy releases create "$RELEASE_NAME" \
  --delivery-pipeline="$PIPELINE" \
  --region="$REGION" \
  --project="$TOOLING_PROJECT" \
  --source="$WORKDIR" \
  --images="${APP_NAME}=${DST_IMAGE}"

echo ""
echo ">> Release '$RELEASE_NAME' dibuat. Rollout ke 'dev' berjalan otomatis."
echo ">> Pantau : gcloud deploy rollouts list --delivery-pipeline=$PIPELINE --release=$RELEASE_NAME --region=$REGION --project=$TOOLING_PROJECT"
echo ">> Promote: gcloud deploy releases promote --release=$RELEASE_NAME --delivery-pipeline=$PIPELINE --region=$REGION --project=$TOOLING_PROJECT"
