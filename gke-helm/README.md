# GKE Deploy — kubectl + Helm (langsung, tanpa Cloud Deploy)

Alternatif *terpisah* dari template Cloud Deploy di [`../gke-clouddeploy/`](../gke-clouddeploy/)
([clouddeploy.yaml](../gke-clouddeploy/clouddeploy.yaml), [release.sh](../gke-clouddeploy/release.sh)).
Dipakai bila ingin deploy langsung ke cluster
GKE lewat `helm upgrade --install`, tanpa registrasi pipeline, tanpa promosi
antar-environment, dan tanpa approval gate.

Cocok untuk: uji cepat di dev, deploy manual dari laptop/runner yang punya
akses `kubectl` ke cluster, atau sebagai basis bila nanti ingin pindah dari
Cloud Deploy ke Helm murni.

## Beda dengan template Cloud Deploy

| | `gke-clouddeploy/release.sh` (Cloud Deploy) | `gke-helm/release.sh` (folder ini) |
|---|---|---|
| Mirror image Nexus → Artifact Registry | Ya (`crane copy`) | **Tidak** — image harus sudah ada di registry Google, atau pull langsung dari Nexus (lihat di bawah) |
| Secret **aplikasi** dari Vault | Ya, dirender jadi `Secret` | **Tidak** — asumsikan `Secret` sudah ada di cluster |
| Kredensial **pull Nexus** dari Vault | Ya (fase 1) | Ya, opsional — `VAULT_NEXUS_PATH` di `.env` |
| Rollout | Cloud Deploy (`gcloud deploy releases create`) | `helm upgrade --install` langsung |
| Promosi antar-environment / approval | Ya (dev → staging → prod) | Tidak — tiap environment = release Helm sendiri |
| Rendering manifest | `sed` placeholder | `values.yaml` Helm |

Kedua template independen — mengubah salah satu tidak memengaruhi yang lain.
Lihat [README.md](../README.md) di root untuk daftar lengkap kedua channel GKE ini.

> **Image argumen wajib sudah di Artifact Registry (`*.pkg.dev`) atau GCR
> (`*gcr.io`)** — node GKE cuma auto-autentikasi ke registry Google. Kalau
> argumen ke-2 menunjuk ke host lain (mis. Nexus on-prem), `release.sh`
> berhenti di detik pertama dengan pesan ini, bukan setelah rollout
> `ImagePullBackOff` timeout beberapa menit. Mirror dulu image-nya (mis.
> `crane copy`, lihat [`gke-clouddeploy/release.sh`](../gke-clouddeploy/release.sh)
> fase 1) sebelum memanggil `release.sh` di sini.

## Struktur

```
gke-helm/
├── .env.example       # parameter koneksi cluster — salin jadi .env
├── release.sh         # entry point: kubectl (get-credentials) + helm upgrade --install
└── chart/             # Helm chart, dikonversi dari ../gke-clouddeploy/manifests/
    ├── Chart.yaml
    ├── values.yaml    # nilai default: image, port, resources, autoscaling, dst.
    └── templates/
        ├── deployment.yaml
        ├── service.yaml     # Internal LoadBalancer secara default
        ├── hpa.yaml         # min 2 / max 6, target CPU 70%
        ├── ingress.yaml     # Internal HTTP LB (gce-internal)
        ├── configmap.yaml
        └── _helpers.tpl
```

## Cara pakai

```bash
cp .env.example .env      # sekali, lalu isi REGION/PROJECT/CLUSTER/NAMESPACE
chmod +x release.sh

./release.sh iris-classifier \
  asia-southeast2-docker.pkg.dev/common-cicd-dev-01/gc-bribrain-dev-gar-temp-01/iris-classifier:v1.2.0
```

`release.sh` akan:
1. `gcloud container clusters get-credentials` — set konteks `kubectl` ke cluster tujuan.
2. Bila `VAULT_NEXUS_PATH` diisi: buat/refresh Secret pull Nexus dari Vault
   (lihat [Pull langsung dari Nexus](#pull-langsung-dari-nexus-tanpa-mirror-ke-artifact-registry)) — dilewati bila kosong.
3. `helm upgrade --install <app> ./chart` dengan `image.repository`/`image.tag`
   dari argumen ke-2, lalu tunggu `kubectl rollout status`.

### Values per environment

Nilai default ada di [`chart/values.yaml`](chart/values.yaml). Untuk environment
lain, buat `values-staging.yaml` dsb. (tidak ikut di-commit bila memuat nilai
spesifik lingkungan) dan berikan sebagai argumen ke-3:

```bash
./release.sh iris-classifier .../iris-classifier:v1.2.0 values-staging.yaml
```

Override cepat tanpa file, lewat `--set` (harus didahului `--`):

```bash
./release.sh iris-classifier .../iris-classifier:v1.2.0 -- --set appPort=8080
```

### Secret aplikasi

Chart ini **tidak membuat** `Secret`. Bila aplikasi butuh secret, buat lebih
dulu di namespace tujuan (manual, lewat pipeline lain, atau External Secrets
Operator), lalu arahkan `secretName` di values ke nama Secret itu:

```yaml
secretName: iris-classifier-secret
```

Kosongkan (default) bila aplikasi tidak butuh secret — `envFrom.secretRef`
tidak akan dipasang sama sekali.

### Pull langsung dari Nexus (tanpa mirror ke Artifact Registry)

Default channel ini mengasumsikan image sudah di Artifact Registry/GCR — node
GKE auto-autentikasi ke sana, tidak perlu Secret apa pun (lihat `release.sh`
yang menolak image di luar `*.pkg.dev`/`*gcr.io` sejak awal). Pull langsung
dari Nexus **bisa** dilakukan — `release.sh` mendukungnya bawaan, kredensial
diambil dari Vault dengan pola yang sama seperti fase 1
[`gke-clouddeploy/release.sh`](../gke-clouddeploy/release.sh).

**Cara pakai** — isi di `.env`:

```bash
NEXUS_HOST=new-nexus.gcp.bri.co.id
VAULT_ADDR=https://vault.ddb.bri.co.id
VAULT_NEXUS_PATH=bribrain/data/development/ms-bribrain-demo-apps
```

lalu jalankan seperti biasa, cukup argumen image menunjuk ke `NEXUS_HOST`:

```bash
export VAULT_TOKEN=hvs....   # dari secret variable CI, JANGAN taruh di .env
./release.sh iris-classifier new-nexus.gcp.bri.co.id/bribrain/dev/iris-classifier:latest
```

Tiap kali dijalankan, `release.sh` akan:
1. Membaca `NEXUS_USER`/`NEXUS_PASS` dari `${VAULT_NEXUS_PATH}` di Vault (key
   sama seperti `.env` — override lewat `VAULT_NEXUS_USER_KEY`/`_PASS_KEY`
   bila nama key-nya beda).
2. Membuat/refresh Secret docker-registry `<app-name>-nexus-pull` di
   `NAMESPACE` — idempoten, aman dipanggil ulang tiap rilis (bukan gagal
   "already exists" di rilis kedua dan seterusnya).
3. Memasangnya otomatis ke `imagePullSecretName` saat `helm upgrade`.

Nilainya tidak pernah masuk log — hanya nama user & nama Secret yang dicetak,
sama seperti `gke-clouddeploy/release.sh`.

Kosongkan `VAULT_NEXUS_PATH` untuk menonaktifkan fitur ini (default) — kembali
ke perilaku semula, image wajib sudah di Artifact Registry/GCR.

#### Dua syarat yang TIDAK dicakup skrip ini

Kredensial hanyalah satu dari tiga syarat pull langsung dari Nexus — dua
lainnya di luar kendali `release.sh`/chart, dan kalau belum terpenuhi pull
tetap gagal meski Secret-nya benar:

1. **Jaringan** — node GKE harus bisa resolve & connect ke `NEXUS_HOST` (VPN/
   Interconnect + firewall bila Nexus benar-benar on-prem). Gejala gagal:
   timeout / `no route to host`.
2. **Kepercayaan TLS** — bila sertifikat Nexus dari CA privat/internal,
   `containerd` di node GKE perlu mempercayainya. Di *managed node* GKE ini
   tidak straightforward (butuh custom node image/startup config). Gejala
   gagal: `x509: certificate signed by unknown authority`.

Kredensial salah/kosong sendiri bergejala `no basic auth credentials` atau
`unauthorized`.

#### Kredensial pull tanpa Vault

Tanpa Vault (`VAULT_NEXUS_PATH` kosong), Secret pull bisa dibuat manual dan
dipasang lewat `imagePullSecretName` + `ALLOW_ANY_REGISTRY=1`:

```bash
kubectl create secret docker-registry nexus-pull \
  --docker-server=new-nexus.gcp.bri.co.id \
  --docker-username=<NEXUS_USER> \
  --docker-password=<NEXUS_PASS> \
  -n <namespace>

ALLOW_ANY_REGISTRY=1 ./release.sh iris-classifier \
  new-nexus.gcp.bri.co.id/bribrain/dev/iris-classifier:latest \
  -- --set imagePullSecretName=nexus-pull
```

Bedanya dari jalur Vault: Secret ini tidak di-refresh otomatis oleh
`release.sh` — rotasi kredensial di Nexus perlu diikuti `kubectl create
secret` ulang secara manual.

### Verifikasi & rollback

```bash
helm status <app-name> -n <namespace>
helm history <app-name> -n <namespace>
helm rollback <app-name> <revisi> -n <namespace>

kubectl get deploy,svc,hpa,ingress -n <namespace> -l app=<app-name>
```

## Prasyarat

`release.sh` memeriksa `kubectl`, `helm`, `gcloud`, dan `gke-gcloud-auth-plugin`
di awal (plus `curl` & `jq` bila `VAULT_NEXUS_PATH` diisi), dan berhenti
dengan saran pemasangan yang sesuai OS bila salah satu belum ada — skrip
tidak meng-install apa pun secara otomatis.

`gke-gcloud-auth-plugin` sering terlewat: `gcloud` bisa saja sudah terpasang
tapi plugin ini belum, dan `kubectl` akan gagal autentikasi ke GKE dengan
pesan `CRITICAL: ACTION REQUIRED: gke-gcloud-auth-plugin ... was not found`.

### Linux (runner) — target sesungguhnya

Runner GCE sering punya `gcloud` terpasang lewat **snap** (`which gcloud` →
`/snap/bin/gcloud`), bukan `apt` maupun installer interaktif. Di situ
`gcloud components install` **ditolak**:

```
ERROR: (gcloud.components.install) You cannot perform this action because
this Google Cloud CLI installation is managed by an external package manager.
```

...dan biasanya **tidak ada paket `apt` google-cloud-sdk/cli terdaftar sama
sekali** (repo-nya memang tidak ditambahkan oleh image snap), jadi
`apt-get install google-cloud-*` juga akan gagal dengan `Unable to locate
package`. Cara yang terbukti jalan di kondisi ini — unduh `kubectl` sebagai
binary resmi, dan tarik `gke-gcloud-auth-plugin` dari installer tarball
terpisah tanpa mengganggu `gcloud` snap yang sedang dipakai untuk auth:

```bash
# kubectl — binary resmi, tidak bergantung cara gcloud terpasang
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# helm
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# gke-gcloud-auth-plugin — installer tarball terpisah, cuma dipakai untuk
# menghasilkan satu binary plugin, gcloud snap tidak disentuh
curl -O https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz
tar -xf google-cloud-cli-linux-x86_64.tar.gz -C "$HOME"
"$HOME/google-cloud-sdk/install.sh" --quiet --path-update false --command-completion false
"$HOME/google-cloud-sdk/bin/gcloud" components install gke-gcloud-auth-plugin --quiet
sudo ln -sf "$HOME/google-cloud-sdk/bin/gke-gcloud-auth-plugin" /usr/local/bin/gke-gcloud-auth-plugin
gke-gcloud-auth-plugin --version   # verifikasi
```

Bila `gcloud` di runner itu ternyata terpasang lewat `apt` (bukan snap),
lebih ringkas:

```bash
sudo apt-get install -y kubectl google-cloud-cli-gke-gcloud-auth-plugin
```

`gcloud components install kubectl` / `... gke-gcloud-auth-plugin` hanya
berlaku bila `gcloud` terpasang lewat installer interaktif (tar.gz) —
periksa dulu dengan `readlink -f "$(which gcloud)"`.

### macOS (uji lokal)

```bash
brew install kubectl helm
brew install --cask gcloud-cli    # bukan `brew install gcloud` — formula itu tidak ada
gcloud components install gke-gcloud-auth-plugin
```

### Akses & jaringan

- Identitas yang menjalankan `release.sh` punya `roles/container.developer`
  (atau lebih) di project **cluster** (`PROJECT` di `.env`) — lihat
  `IMPERSONATE_SA` di `.env.example` bila ingin menjalankan sebagai service
  account.
- Ingress internal (`gce-internal`) butuh proxy-only subnet & firewall internal
  LB di VPC. Bila belum tersedia, set `ingress.enabled: false` di values.

#### Cluster di project GCP berbeda dari VM/runner

`PROJECT`/`CLUSTER` di `.env` **tidak harus** project yang sama dengan tempat
VM `release.sh` berjalan — `gcloud container clusters get-credentials
--project=$PROJECT` selalu menyasar project itu secara eksplisit, apa pun
project asal VM.

Yang perlu diperiksa: identitas efektif (SA VM, atau `IMPERSONATE_SA` bila
diisi) butuh izin di project **cluster**, bukan di project VM:

```bash
gcloud projects add-iam-policy-binding <PROJECT-CLUSTER> \
  --member="serviceAccount:<SA-VM-atau-IMPERSONATE_SA>" \
  --role="roles/container.developer"
```

Tanpa ini, `gcloud container clusters get-credentials` gagal `403` meski
kredensial VM valid — bukan soal salah akun, tapi akun itu belum punya izin
di project cluster-nya.
