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

# ---------- Prasyarat perkakas ----------
# Dicek SEKALIGUS di awal: sebelumnya `crane` yang belum terpasang baru terdeteksi
# di tengah fase 1, setelah Vault sudah dibaca. Sintaks tanpa array supaya jalan
# di bash 3.2 (bawaan macOS).
MISSING=""
for t in crane gcloud; do
  command -v "$t" >/dev/null 2>&1 || MISSING="$MISSING $t"
done
if [[ -n "${VAULT_ADDR:-}" ]]; then
  for t in curl jq; do
    command -v "$t" >/dev/null 2>&1 || MISSING="$MISSING $t"
  done
fi
if [[ -n "$MISSING" ]]; then
  echo "!! Perkakas belum terpasang:$MISSING" >&2

  # Saran pemasangan disesuaikan OS: runner sesungguhnya Linux (GCE), sedangkan
  # macOS hanya dipakai untuk uji lokal. Nama paket brew: `gcloud-cli` (cask),
  # bukan `gcloud` — formula bernama `gcloud` tidak ada.
  CRANE_ARCH="$(uname -m)"
  case "$CRANE_ARCH" in
    aarch64|arm64) CRANE_ARCH=arm64 ;;
    x86_64|amd64)  CRANE_ARCH=x86_64 ;;
  esac
  CRANE_URL="https://github.com/google/go-containerregistry/releases/latest/download/go-containerregistry_$(uname -s)_${CRANE_ARCH}.tar.gz"

  for t in $MISSING; do
    if [[ "$(uname -s)" == "Darwin" ]]; then
      case "$t" in
        crane)  echo "   crane  : brew install crane" >&2 ;;
        jq)     echo "   jq     : brew install jq" >&2 ;;
        curl)   echo "   curl   : bawaan OS - periksa PATH" >&2 ;;
        gcloud) echo "   gcloud : brew install --cask gcloud-cli" >&2 ;;
      esac
    else
      case "$t" in
        crane)  echo "   crane  : curl -sSL $CRANE_URL | sudo tar -xz -C /usr/local/bin crane" >&2 ;;
        jq)     echo "   jq     : sudo apt-get install -y jq   # atau: dnf install jq" >&2 ;;
        curl)   echo "   curl   : sudo apt-get install -y curl" >&2 ;;
        gcloud) echo "   gcloud : https://cloud.google.com/sdk/docs/install" >&2 ;;
      esac
    fi
  done
  echo "   Detail : README bagian 'Prasyarat perkakas'" >&2
  exit 1
fi

# Vault opsional, tapi bila diaktifkan cek prasyaratnya SEKARANG — jangan sampai
# gagal setelah mirror image (fase 1) sudah terlanjur jalan.
if [[ -n "${VAULT_ADDR:-}" ]]; then
  [[ -n "${VAULT_TOKEN:-}" ]] || {
    echo "!! VAULT_ADDR diisi tapi VAULT_TOKEN kosong." >&2
    echo "   Set lewat env var dari CI (bukan .env): export VAULT_TOKEN=..." >&2
    exit 1
  }
elif [[ -n "${VAULT_NEXUS_PATH:-}" ]]; then
  echo "!! VAULT_NEXUS_PATH diisi tapi VAULT_ADDR kosong." >&2
  exit 1
fi

# Impersonasi service account (opsional). Diterapkan ke SEMUA pemanggilan gcloud
# — token AR, deploy apply, dan releases create — supaya identitasnya konsisten.
# Memakai impersonasi lebih baik daripada mengunduh kunci JSON SA.
IMPERSONATE_SA="${IMPERSONATE_SA:-}"
GCLOUD_IMP=""
if [[ -n "$IMPERSONATE_SA" ]]; then
  GCLOUD_IMP="--impersonate-service-account=$IMPERSONATE_SA"
fi

# Member IAM untuk pesan bantuan: SA dan akun perorangan punya prefiks berbeda.
iam_member() {
  local acct
  if [[ -n "$IMPERSONATE_SA" ]]; then
    acct="$IMPERSONATE_SA"
  else
    acct="$(gcloud config get-value account 2>/dev/null || true)"
  fi
  case "$acct" in
    *gserviceaccount.com) echo "serviceAccount:$acct" ;;
    "")                   echo "<akun-anda>" ;;
    *)                    echo "user:$acct" ;;
  esac
}

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
# Artifact Registry boleh berada di project sendiri, terpisah dari project
# tooling Cloud Deploy. Default: ikut TOOLING_PROJECT (perilaku lama).
AR_PROJECT="${AR_PROJECT:-$TOOLING_PROJECT}"

SRC_IMAGE="${NEXUS_HOST}/${NEXUS_PATH}/${APP_NAME}:${IMAGE_TAG}"
DST_IMAGE="${AR_HOST}/${AR_PROJECT}/${AR_REPO}/${APP_NAME}:${IMAGE_TAG}"
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
echo " AR project : $AR_PROJECT / $AR_REPO"
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
if [[ -n "$IMPERSONATE_SA" ]]; then
  echo " Identitas  : $IMPERSONATE_SA (impersonasi)"
else
  echo " Identitas  : $(gcloud config get-value account 2>/dev/null || echo '?')"
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

# Login ke Artifact Registry secara eksplisit dengan access token gcloud.
#
# Sengaja TIDAK mengandalkan credential helper docker (`gcloud auth
# configure-docker`): `crane` memanggil biner `docker-credential-gcloud`, dan
# bila biner itu tidak ada di PATH ia diam-diam jatuh ke permintaan anonim.
# Gejalanya menyesatkan — "DENIED: Unauthenticated request ... uploadArtifacts"
# yang terbaca seolah SA kurang izin, padahal tidak ada kredensial terkirim.
case "$AR_HOST" in
  *.pkg.dev|*gcr.io)
    echo "   Login ke Artifact Registry: $AR_HOST"
    AR_TOKEN="$(gcloud auth print-access-token $GCLOUD_IMP 2>/dev/null)" || AR_TOKEN=""
    if [[ -z "$AR_TOKEN" ]]; then
      echo "!! Gagal mengambil access token gcloud untuk $AR_HOST." >&2
      if [[ -n "$IMPERSONATE_SA" ]]; then
        echo "   Sedang mengimpersonasi: $IMPERSONATE_SA" >&2
        echo "   Akun pemanggil butuh roles/iam.serviceAccountTokenCreator pada SA itu:" >&2
        echo "     gcloud iam service-accounts add-iam-policy-binding $IMPERSONATE_SA \\" >&2
        echo "       --member='$(iam_member)' --role='roles/iam.serviceAccountTokenCreator'" >&2
      else
        echo "   Di VM GCE : VM butuh scope 'cloud-platform'. Periksa dengan:" >&2
        echo "     curl -s -H 'Metadata-Flavor: Google' \\" >&2
        echo "       http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/scopes" >&2
        echo "   Di luar   : jalankan 'gcloud auth login', atau set IMPERSONATE_SA." >&2
      fi
      exit 1
    fi
    printf '%s' "$AR_TOKEN" \
      | crane auth login "$AR_HOST" -u oauth2accesstoken --password-stdin
    unset AR_TOKEN
    ;;
  *)
    echo "   AR_HOST bukan host Google ($AR_HOST) - login AR dilewati." >&2
    ;;
esac

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

  # Tiga kondisi berbeda, jangan disamakan:
  #   a. ada key untuk pod            -> normal
  #   b. semua key tersaring          -> normal, path itu memang hanya infra
  #   c. Vault balas tanpa key sama sekali -> patut dicurigai (path salah?)
  if [[ -n "$SECRET_BODY" ]]; then
    echo "   OK - versi $VERSION, key ke pod: $KEPT"
  elif [[ -n "$DROPPED" ]]; then
    echo "   OK - versi $VERSION, tidak ada secret aplikasi di path ini."
    echo "        Secret pod dirender kosong; aplikasi memakai ConfigMap saja."
  else
    echo "   !! Vault balas tanpa key apa pun (versi $VERSION) - periksa VAULT_SECRET_PATH." >&2
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

# Mendaftarkan pipeline butuh roles/clouddeploy.developer, sedangkan membuat
# release cukup roles/clouddeploy.releaser. Di lingkungan dengan akun terbatas,
# admin menjalankan `gcloud deploy apply` sekali, lalu rilis harian jalan dengan
# SKIP_PIPELINE_APPLY=1 memakai izin yang lebih rendah.
if [[ -n "${SKIP_PIPELINE_APPLY:-}" ]]; then
  echo "   Lewati 'deploy apply' (SKIP_PIPELINE_APPLY diisi)."
  echo "   Pipeline & target dianggap sudah terdaftar; perubahan pada"
  echo "   clouddeploy.yaml TIDAK akan diterapkan pada rilis ini."
else
  if ! gcloud deploy apply \
        --file="$WORKDIR/clouddeploy.yaml" \
        --region="$REGION" \
        --project="$TOOLING_PROJECT" $GCLOUD_IMP; then
    echo "" >&2
    echo "!! Gagal mendaftarkan pipeline di $TOOLING_PROJECT." >&2
    echo "   Bila pesannya 403 'clouddeploy.deliveryPipelines.update denied':" >&2
    echo "   identitas pemanggil kurang izin. Dua jalan keluar:" >&2
    echo "" >&2
    echo "   1) Beri roles/clouddeploy.developer pada $TOOLING_PROJECT:" >&2
    echo "      gcloud projects add-iam-policy-binding $TOOLING_PROJECT \\" >&2
    echo "        --member='$(iam_member)' \\" >&2
    echo "        --role='roles/clouddeploy.developer'" >&2
    echo "" >&2
    echo "   2) Minta admin menjalankan 'gcloud deploy apply' sekali, lalu rilis" >&2
    echo "      berikutnya cukup roles/clouddeploy.releaser:" >&2
    echo "      SKIP_PIPELINE_APPLY=1 ./release.sh $APP_NAME $IMAGE_TAG" >&2
    exit 1
  fi
fi

# Buat release; image aktual diinjeksikan lewat --images
gcloud deploy releases create "$RELEASE_NAME" \
  --delivery-pipeline="$PIPELINE" \
  --region="$REGION" \
  --project="$TOOLING_PROJECT" \
  --source="$WORKDIR" \
  --images="${APP_NAME}=${DST_IMAGE}" $GCLOUD_IMP

echo ""
echo ">> Release '$RELEASE_NAME' dibuat. Rollout ke 'dev' berjalan otomatis."
echo ">> Pantau : gcloud deploy rollouts list --delivery-pipeline=$PIPELINE --release=$RELEASE_NAME --region=$REGION --project=$TOOLING_PROJECT"
echo ">> Promote: gcloud deploy releases promote --release=$RELEASE_NAME --delivery-pipeline=$PIPELINE --region=$REGION --project=$TOOLING_PROJECT"
