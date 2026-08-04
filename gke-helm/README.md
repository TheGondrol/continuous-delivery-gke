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
| Mirror image Nexus → Artifact Registry | Ya (`crane copy`) | **Tidak** — image harus sudah ada di registry |
| Secret dari Vault | Ya, dirender jadi `Secret` | **Tidak** — asumsikan `Secret` sudah ada di cluster |
| Rollout | Cloud Deploy (`gcloud deploy releases create`) | `helm upgrade --install` langsung |
| Promosi antar-environment / approval | Ya (dev → staging → prod) | Tidak — tiap environment = release Helm sendiri |
| Rendering manifest | `sed` placeholder | `values.yaml` Helm |

Kedua template independen — mengubah salah satu tidak memengaruhi yang lain.
Lihat [README.md](../README.md) di root untuk daftar lengkap kedua channel GKE ini.

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
2. `helm upgrade --install <app> ./chart` dengan `image.repository`/`image.tag`
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

### Verifikasi & rollback

```bash
helm status <app-name> -n <namespace>
helm history <app-name> -n <namespace>
helm rollback <app-name> <revisi> -n <namespace>

kubectl get deploy,svc,hpa,ingress -n <namespace> -l app=<app-name>
```

## Prasyarat

`release.sh` memeriksa `kubectl`, `helm`, `gcloud`, dan `gke-gcloud-auth-plugin`
di awal, dan berhenti dengan saran pemasangan yang sesuai OS bila salah satu
belum ada — skrip tidak meng-install apa pun secara otomatis.

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
