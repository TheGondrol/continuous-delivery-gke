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

- `kubectl`, `helm` (v3), `gcloud` terpasang di runner/laptop.
- Identitas yang menjalankan `release.sh` punya `roles/container.developer`
  (atau lebih) di project cluster — lihat `IMPERSONATE_SA` di `.env.example`
  bila ingin menjalankan sebagai service account.
- Ingress internal (`gce-internal`) butuh proxy-only subnet & firewall internal
  LB di VPC. Bila belum tersedia, set `ingress.enabled: false` di values.
