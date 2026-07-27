# CD Template — Cloud Deploy → GKE

Template standar *reusable* untuk men-deliver image (dari Nexus, hasil CI on-prem)
ke **GKE** via **Cloud Deploy**, lengkap dengan promosi antar-environment dan
approval sebelum prod. Konsisten dengan template channel Cloud Run & VM/GCE.

Satu template dipakai banyak aplikasi — nama app, port, project, dan cluster
semuanya parameter, bukan nilai hardcode.

---

## Alur

```
[CI on-prem] → image di Nexus            Vault on-prem
      │  ./release.sh <app> <tag>          │
      ▼                                    │
  FASE 1  crane login+copy  ◄── kredensial Nexus (tetap di runner)
          Nexus ──► Artifact Registry      │
      │                                    │
      ▼                                    ▼
  FASE 2  render manifest  ◄──── secret aplikasi ──► manifests/secret.yaml
      │                                              (workdir sementara)
      ▼
  FASE 3  Cloud Deploy release ──► rollout ke cluster `dev`
                                   └─ promote ──► staging ──► (approval) ──► prod
```

---

## Struktur repo

```
.
├── .env.example          # daftar parameter — salin jadi .env, lalu isi
├── .gitignore            # .env (berisi kredensial) tidak ikut ter-commit
├── clouddeploy.yaml      # Delivery Pipeline + Targets GKE
├── skaffold.yaml         # resep render & deploy (kubectl)
├── release.sh            # entry point: mirror image + tarik secret + buat release
└── manifests/
    ├── configmap.yaml    # environment variables aplikasi (non-sensitif)
    ├── (secret.yaml)     # TIDAK di repo — digenerate release.sh dari Vault
    ├── deployment.yaml   # pod: probes, resources, envFrom ConfigMap + Secret
    ├── service.yaml      # expose via Internal LoadBalancer (VPC only)
    ├── hpa.yaml          # autoscaling CPU (min 2, max 6)
    └── ingress.yaml      # Internal HTTP LB (gce-internal), routing path-based
```

---

## Parameter (`.env`)

Semua nilai yang perlu disesuaikan ada di satu tempat. **`.env` tidak di-commit**
(berisi kredensial Nexus) — `.env.example` adalah acuannya.

```bash
cp .env.example .env
```

| Variabel | Isi | Wajib |
|---|---|:--:|
| `REGION` | Region Cloud Deploy & cluster, mis. `asia-southeast2` | ✅ |
| `APP_PORT` | Port yang di-listen container | ✅ |
| `TOOLING_PROJECT` | Project tempat pipeline Cloud Deploy didaftarkan | ✅ |
| `AR_HOST` / `AR_REPO` | Host & repo Artifact Registry tujuan mirror | ✅ |
| `AR_PROJECT` | Project tempat repo AR berada. Kosong = ikut `TOOLING_PROJECT` | — |
| `NEXUS_HOST` / `NEXUS_PATH` | Sumber image hasil CI on-prem | ✅ |
| `NEXUS_USER` / `NEXUS_PASS` | Cadangan untuk runner tanpa Vault. Kosongkan bila `VAULT_NEXUS_PATH` dipakai | — |
| `VAULT_ADDR` | URL Vault on-prem. **Kosongkan untuk menonaktifkan** fitur secret | — |
| `VAULT_MOUNT` / `VAULT_ENV` | Mount KV v2 & environment, mis. `bribrain` / `development` | ⬦ |
| `VAULT_SECRET_PATH` | Override path penuh bila tidak mengikuti nama app | — |
| `VAULT_NEXUS_PATH` | Path kredensial Nexus di Vault. Kosong = pakai `NEXUS_USER`/`NEXUS_PASS` | — |
| `VAULT_NEXUS_USER_KEY` / `..._PASS_KEY` | Nama key di secret itu. Default `NEXUS_USER` / `NEXUS_PASS` — jarang perlu diubah | — |
| `VAULT_SECRET_EXCLUDE_KEYS` | Key tambahan yang tidak boleh ikut ke pod (dipisah koma) | — |
| `DEV_PROJECT` / `DEV_CLUSTER` | Target cluster dev | ✅ |
| `STAGING_PROJECT` / `STAGING_CLUSTER` | Diisi saat staging diaktifkan | — |
| `PROD_PROJECT` / `PROD_CLUSTER` | Diisi saat prod diaktifkan | — |

⬦ = wajib bila `VAULT_ADDR` diisi (kecuali `VAULT_SECRET_PATH` dipakai).

`release.sh` gagal cepat dengan pesan jelas bila variabel wajib kosong — termasuk
prasyarat Vault, yang dicek **sebelum** mirror image dijalankan.

### `VAULT_TOKEN` — sengaja tidak ada di `.env`

Token disuplai lewat env var dari secret variable CI supaya tidak pernah menyentuh
disk runner:

```bash
export VAULT_TOKEN=hvs....      # dari CI, bukan diketik manual
./release.sh iris-classifier v1.2.0
```

Env var dari shell **menang** atas `.env`, berguna untuk override sekali-jalan:

```bash
APP_PORT=8080 ./release.sh other-app latest
```

`DEV_PROJECT` / `DEV_CLUSTER` / `REGION` bisa dibaca langsung dari nama context
kubeconfig, yang berformat `gke_<PROJECT>_<LOCATION>_<CLUSTER>`:

```
gke_ddb-kubecluster-dev-01_asia-southeast2_gc-ddb-dev-gke-cluster-01
    └── DEV_PROJECT ────┘ └── REGION ──┘ └── DEV_CLUSTER ─────────┘
```

Cek context yang ada di runner, atau daftar cluster di project itu:

```bash
kubectl config get-contexts -o name
gcloud container clusters list --project=ddb-kubecluster-dev-01
```

---

## Cara pakai

```bash
cp .env.example .env      # sekali, lalu isi DEV_CLUSTER dkk.
chmod +x release.sh
./release.sh iris-classifier v1.2.0
```

`release.sh` akan:
1. Mirror `NEXUS_HOST/NEXUS_PATH/<app>:<tag>` → Artifact Registry (`crane copy`).
2. Menyalin template ke workdir sementara & mengganti placeholder dari `.env`.
3. Membaca Vault KV v2, lalu merender `manifests/secret.yaml` di workdir itu.
4. `gcloud deploy apply` — daftarkan/refresh pipeline & target.
5. `gcloud deploy releases create` — image aktual diinjeksi lewat `--images`.

---

## Secret dari Vault

Vault dibaca di dua tempat, untuk dua keperluan berbeda:

| Path | Isi | Dipakai di |
|---|---|---|
| `VAULT_NEXUS_PATH` | Kredensial registry Nexus | Fase 1 — `crane auth login` di runner |
| `VAULT_SECRET_PATH` | Secret aplikasi | Fase 2 — jadi env var di pod |

Yang pertama tidak pernah meninggalkan runner. Yang kedua ikut ke cluster.
Keduanya **boleh menunjuk path yang sama** — `release.sh` menyaring key kredensial
runner agar tidak ikut ke pod (lihat di bawah).

### Kredensial Nexus

Pathnya diisi eksplisit, tidak diturunkan dari nama app:

```bash
VAULT_NEXUS_PATH=bribrain/data/development/ms-bribrain-demo-apps
```

Key di dalam secret itu bernama `NEXUS_USER` dan `NEXUS_PASS` — sama dengan nama
variabel `.env`-nya, jadi itulah default `release.sh` dan tidak perlu diatur.
`VAULT_NEXUS_USER_KEY` / `VAULT_NEXUS_PASS_KEY` hanya diperlukan bila suatu saat
ada path Vault yang memakai nama key berbeda.

#### Kredensial runner disaring dari Secret pod

Di layout Vault ini, kredensial Nexus berada di **path yang sama** dengan secret
aplikasi. Tanpa penjagaan, `NEXUS_USER`/`NEXUS_PASS` akan ikut jadi env var di
pod sekaligus tersimpan di bucket render Cloud Deploy — kredensial registry
tersebar ke tempat yang tidak membutuhkannya.

Karena itu `release.sh` **selalu** membuang kedua key itu saat merender
`secret.yaml`, dan melaporkan apa yang dibuang:

```
   OK - versi 5, key ke pod: DB_PASSWORD, MODEL_PATH
   Dikecualikan (kredensial runner, tidak ke pod): NEXUS_USER, NEXUS_PASS
```

Bila ada nilai non-aplikasi lain di path yang sama, tambahkan ke daftar saring:

```bash
VAULT_SECRET_EXCLUDE_KEYS=DOCKER_TOKEN,GIT_PAT
```

> Menaruh kredensial infra di path per-app membuat setiap app yang membacanya
> ikut memegang kredensial registry. Bila nanti ada kesempatan merapikan,
> pindahkan ke path infra tersendiri (mis. `bribrain/data/infra/nexus`) dengan
> token read-only terpisah — saringan ini menutup gejalanya, bukan sebabnya.

Bila diisi, Vault menang atas `NEXUS_USER`/`NEXUS_PASS` di `.env`. Kosongkan
`VAULT_NEXUS_PATH` untuk kembali memakai nilai `.env` — berguna untuk runner
yang belum punya akses Vault.

Password dialirkan ke `crane` lewat `--password-stdin`, jadi tidak pernah tampil
di daftar proses (`ps`) selama mirror berjalan. Bila nama key tidak cocok,
`release.sh` menyebutkan key apa saja yang sebenarnya ada di path itu.

### Secret aplikasi

Aplikasi menerima secret sebagai environment variable, lewat `envFrom.secretRef`
di [`manifests/deployment.yaml`](manifests/deployment.yaml) — persis seperti
ConfigMap, jadi kode aplikasi tidak perlu tahu asalnya dari Vault.

Path default mengikuti nama app:

```
<VAULT_MOUNT>/data/<VAULT_ENV>/<app-name>
   bribrain  /data/ development / iris-classifier
```

Segmen `data/` itu penanda **KV v2** — nilainya ada di `.data.data`, bukan `.data`.
Cek isi sebuah path secara manual:

```bash
curl -s -H "X-Vault-Token: $VAULT_TOKEN" \
  "$VAULT_ADDR/v1/bribrain/data/development/iris-classifier" \
| jq -r '.data.data | keys'          # keys saja — jangan cetak nilainya
```

Bila path di Vault tidak mengikuti nama app, timpa penuh:

```bash
VAULT_SECRET_PATH=bribrain/data/development/ms-bribrain-demo-apps \
  ./release.sh iris-classifier v1.2.0
```

Setiap key di Vault jadi satu env var di pod. Menambah key di Vault cukup diikuti
rilis ulang — tidak ada perubahan manifest.

### Yang perlu diketahui soal pola ini

- **Secret ikut tersimpan di artefak Cloud Deploy.** `--source` diunggah ke bucket
  render Cloud Deploy (`gs://<project>_clouddeploy/`), dan `stringData` di sana
  berupa teks biasa. Siapa pun yang bisa membaca bucket itu bisa membaca secret —
  batasi aksesnya seketat cluster. Ini konsekuensi yang dipilih sadar demi
  menjaga `release.sh` tidak perlu kredensial kubectl ke tiap cluster.
- **Rotasi tidak otomatis.** Mengubah nilai di Vault tidak mengubah pod yang
  sedang jalan; perlu rilis ulang. Bila butuh rotasi hidup, pindah ke External
  Secrets Operator — tapi itu menuntut jalur jaringan GKE → Vault on-prem.
- **Nilai tidak pernah masuk log.** `release.sh` hanya mencetak nama key dan
  nomor versi secret.
- **`secret.yaml` tidak pernah ada di repo.** Hanya di workdir `mktemp` ber-`chmod 700`
  yang dihapus lewat `trap` saat skrip selesai — sukses maupun gagal.
- **Substitusi `sed` tidak menyentuhnya.** Secret dirender *setelah* loop
  placeholder, supaya nilai yang kebetulan memuat string `REGION` atau `APP_NAME`
  tidak ikut tergantikan.

Rollout ke `dev` berjalan otomatis. Nama release: `rel-<YYYYmmdd-HHMMSS>`.

### Pantau & promosi

```bash
# rollout
gcloud deploy rollouts list \
  --delivery-pipeline=iris-classifier-gke-pipeline \
  --release=<RELEASE> --region=asia-southeast2 --project=edm-bribrain-dev-01

# promote ke stage berikutnya
gcloud deploy releases promote \
  --release=<RELEASE> --delivery-pipeline=iris-classifier-gke-pipeline \
  --region=asia-southeast2 --project=edm-bribrain-dev-01

# approve rollout prod yang menunggu
gcloud deploy rollouts approve <ROLLOUT> \
  --delivery-pipeline=iris-classifier-gke-pipeline --release=<RELEASE> \
  --region=asia-southeast2 --project=edm-bribrain-dev-01
```

### Verifikasi di cluster

```bash
gcloud container clusters get-credentials <CLUSTER> \
  --region=asia-southeast2 --project=edm-bribrain-dev-01
kubectl get deploy,svc,hpa,ingress -l app=iris-classifier
```

---

## Placeholder yang disubstitusi

`release.sh` merender template di workdir sementara — file di repo tetap bersih.

| Placeholder | Sumber | Muncul di |
|---|---|---|
| `APP_NAME` | argumen ke-1 `release.sh` | semua YAML |
| `APP_PORT` | `.env` | `deployment.yaml`, `service.yaml` |
| `REGION`, `DEV_PROJECT`, `DEV_CLUSTER` | `.env` | `clouddeploy.yaml` |
| field `image:` | `--images` Cloud Deploy | `deployment.yaml` |

---

## Prasyarat perkakas

`release.sh` memeriksa semuanya di awal dan berhenti dengan daftar yang kurang,
sebelum menyentuh Vault maupun registry.

| Perkakas | Untuk | Wajib |
|---|---|:--:|
| `crane` | Mirror image Nexus → AR | ✅ |
| `gcloud` | `deploy apply` & `releases create` | ✅ |
| `curl` + `jq` | Baca secret dari Vault | bila `VAULT_ADDR` diisi |

`release.sh` menyesuaikan saran pemasangannya dengan OS tempat ia dijalankan.

### Runner Linux (GCE) — target sesungguhnya

`gcloud` sudah tersedia di image GCE bawaan Google. Yang perlu ditambahkan
hanyalah `crane` (`jq` & `curl` biasanya sudah ada):

```bash
# crane — arch x86_64; ganti ke arm64 untuk VM Tau/Axion
curl -sSL "https://github.com/google/go-containerregistry/releases/latest/download/go-containerregistry_Linux_x86_64.tar.gz" \
  | sudo tar -xz -C /usr/local/bin crane
crane version

# jq bila belum ada
sudo apt-get install -y jq        # Debian/Ubuntu
```

Lalu sekali saja, agar `crane` bisa push ke Artifact Registry memakai service
account VM:

```bash
gcloud auth configure-docker asia-southeast2-docker.pkg.dev
```

> VM butuh **scope** `cloud-platform` (atau minimal `devstorage.read_write`) dan
> SA-nya butuh `roles/artifactregistry.writer` di `common-cicd-dev-01` — lihat
> setup no. 2. Scope tidak bisa diubah saat VM menyala; kalau kurang, hentikan
> VM dulu atau pakai VM baru.

### macOS — hanya untuk uji lokal

```bash
brew install crane jq
brew install --cask gcloud-cli     # bukan `brew install gcloud` — formula itu tidak ada
```

---

## Setup sekali-jalan (per project tooling)

> Sebagian butuh izin admin — ajukan ke tim Cloud BRI bila akun terbatas.

### 1. Aktifkan API

Di project **tooling** (tempat pipeline didaftarkan):

```bash
gcloud services enable \
  clouddeploy.googleapis.com \
  container.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  --project=edm-bribrain-dev-01
```

Di project **cluster** (agar Cloud Deploy bisa memanggil GKE di sana):

```bash
gcloud services enable container.googleapis.com \
  --project=ddb-kubecluster-dev-01
```

### 2. Repo Artifact Registry (tujuan mirror)

AR berada di project **sendiri** (`AR_PROJECT`), terpisah dari project tooling:

```bash
gcloud services enable artifactregistry.googleapis.com \
  --project=common-cicd-dev-01

gcloud artifacts repositories create gc-bribrain-dev-gar-temp-01 \
  --repository-format=docker \
  --location=asia-southeast2 \
  --project=common-cicd-dev-01
```

Lalu izinkan `crane` di runner mem-push ke sana. Tanpa langkah ini, Fase 1 gagal
saat push meski `crane` sudah login ke Nexus:

```bash
# helper kredensial docker untuk host AR (sekali per runner)
gcloud auth configure-docker asia-southeast2-docker.pkg.dev

# identitas runner butuh izin tulis di project AR
gcloud artifacts repositories add-iam-policy-binding gc-bribrain-dev-gar-temp-01 \
  --location=asia-southeast2 --project=common-cicd-dev-01 \
  --member="serviceAccount:<SA-RUNNER>" --role="roles/artifactregistry.writer"
```

### 3. Izin service account — lintas tiga project

Rilis ini menyentuh **tiga project berbeda**, masing-masing dengan perannya:

| Project | Peran | Variabel |
|---|---|---|
| `edm-bribrain-dev-01` | Pipeline & release Cloud Deploy terdaftar di sini | `TOOLING_PROJECT` |
| `common-cicd-dev-01` | Repo Artifact Registry (image disimpan) | `AR_PROJECT` |
| `ddb-kubecluster-dev-01` | Cluster GKE tujuan deploy | `DEV_PROJECT` |

Karena ketiganya terpisah, izin harus diberikan **di project tujuan masing-masing**
— memberi semua role di satu project tidak akan cukup.

```bash
TOOLING_PROJECT=edm-bribrain-dev-01
DEV_PROJECT=ddb-kubecluster-dev-01
AR_PROJECT=common-cicd-dev-01
AR_REPO=gc-bribrain-dev-gar-temp-01

# SA eksekutor Cloud Deploy — milik project TOOLING
TP_NUMBER=$(gcloud projects describe $TOOLING_PROJECT --format='value(projectNumber)')
SA="${TP_NUMBER}-compute@developer.gserviceaccount.com"

# --- di project TOOLING: menjalankan operasi Cloud Deploy ---
gcloud projects add-iam-policy-binding $TOOLING_PROJECT \
  --member="serviceAccount:${SA}" --role="roles/clouddeploy.jobRunner"
gcloud projects add-iam-policy-binding $TOOLING_PROJECT \
  --member="serviceAccount:${SA}" --role="roles/iam.serviceAccountUser"

# --- di project CLUSTER: menerapkan manifest ke GKE ---
gcloud projects add-iam-policy-binding $DEV_PROJECT \
  --member="serviceAccount:${SA}" --role="roles/container.developer"

# --- di project AR: membaca manifest & image saat render ---
gcloud artifacts repositories add-iam-policy-binding "$AR_REPO" \
  --location=asia-southeast2 --project="$AR_PROJECT" \
  --member="serviceAccount:${SA}" --role="roles/artifactregistry.reader"
```

> Ulangi blok "project CLUSTER" untuk staging/prod saat environment itu diaktifkan.

#### Izin pull image oleh node GKE (paling mudah terlewat)

Yang mem-*pull* image adalah service account **node pool**, bukan SA Cloud Deploy.
Repo AR ada di `common-cicd-dev-01` sementara node ada di `ddb-kubecluster-dev-01`,
jadi SA node harus diberi izin baca lintas project. Tanpa ini rollout **tampak
sukses** lalu pod berhenti di `ImagePullBackOff`:

```bash
# cari SA node pool yang sebenarnya dipakai
gcloud container node-pools list \
  --cluster=gc-ddb-dev-gke-cluster-01 --region=asia-southeast2 \
  --project=ddb-kubecluster-dev-01 --format='value(name,config.serviceAccount)'

gcloud artifacts repositories add-iam-policy-binding gc-bribrain-dev-gar-temp-01 \
  --location=asia-southeast2 --project=common-cicd-dev-01 \
  --member="serviceAccount:<SA-NODE>" --role="roles/artifactregistry.reader"
```

> Bila `config.serviceAccount` berisi `default`, yang dipakai adalah
> `<PROJECT_NUMBER>-compute@developer.gserviceaccount.com` milik
> `ddb-kubecluster-dev-01` — bukan milik project tooling.

### 4. Prasyarat jaringan (internal LB / ingress)

- **Internal LoadBalancer** — subnet cluster mendukung internal LB (umumnya default).
- **Internal Ingress** (`gce-internal`) — butuh **proxy-only subnet** di region &
  firewall internal LB, biasanya disiapkan tim jaringan. Bila belum ada, Ingress
  akan *pending*: hapus `manifests/ingress.yaml` dari daftar di `skaffold.yaml`
  sampai subnet tersedia.

### 5. Kredensial Nexus untuk `crane`

Urutan prioritas: **Vault** → `.env` → sesi `crane` yang sudah login.

- **Vault (dianjurkan):** isi `VAULT_NEXUS_PATH` di `.env`. Tidak ada kredensial
  Nexus yang tersimpan di disk runner.
- Cadangan: isi `NEXUS_USER` / `NEXUS_PASS` di `.env`, **atau**
- `crane auth login new-nexus.gcp.bri.co.id` sekali di runner (lalu kosongkan semua).

### 6. Akses Vault dari runner

- Runner butuh `curl` & `jq`, serta jalur jaringan ke `vault.ddb.bri.co.id`.
- Minta ke tim Vault: token (atau AppRole) dengan **read-only** pada path
  `bribrain/data/<env>/*` **dan** path kredensial Nexus (mis. `bribrain/data/infra/nexus`).
  Simpan sebagai secret variable di CI, bukan di `.env`.
- Batasi pembaca bucket render Cloud Deploy (`gs://<TOOLING_PROJECT>_clouddeploy/`) —
  lihat catatan di bagian *Secret dari Vault*.

---

## Status desain saat ini

- **Environment aktif:** `dev` saja — staging & prod disiapkan tapi masih commented.
- **Approval:** target `prod` pakai `requireApproval: true`.
- **Project:** terpisah per environment. Artifact Registry punya project sendiri
  (`AR_PROJECT`), dipakai bersama semua environment — jadi setiap cluster butuh
  izin baca lintas project.
- **Jaringan:** internal only — Service = Internal LB, Ingress = internal HTTP LB.
- **Secret:** ditarik dari Vault on-prem saat rilis, dirender jadi Kubernetes
  Secret di workdir sementara, di-apply Cloud Deploy bersama manifest lain.
  ConfigMap tetap hanya untuk nilai non-sensitif.

### Mengaktifkan staging & prod

1. Isi `STAGING_*` / `PROD_*` di `.env`.
2. Uncomment target di `clouddeploy.yaml` + stage di `serialPipeline`.
3. Uncomment profile terkait di `skaffold.yaml`.
4. Ulangi setup sekali-jalan (API, AR, IAM SA, jaringan) di project tujuan.

---

## Konsistensi 3 channel

Channel VM/GCE, Cloud Run, dan GKE mengikuti pola yang sama:

- Satu folder template per channel.
- Antarmuka seragam: `./release.sh <app> <tag>` (atau `deploy.sh` untuk VM).
- Konfigurasi terpusat di `.env`.
- Fase mirror Nexus→AR identik (kecuali VM yang bisa pull langsung dari Nexus).

Simpan sebagai `cd-templates/{gce,cloudrun,gke}/` di repo standar.
