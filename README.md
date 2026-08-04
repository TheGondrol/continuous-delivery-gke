# Continuous Delivery — GKE

Dua cara deploy ke **GKE** yang tersedia di repo ini, tergantung kebutuhan:

| Folder | Cara rollout | Kapan dipakai |
|---|---|---|
| [`gke-clouddeploy/`](gke-clouddeploy/) | Google **Cloud Deploy** — pipeline, promosi antar-environment (dev → staging → prod), approval gate | Rilis terkelola, butuh jejak audit & promosi bertahap |
| [`gke-helm/`](gke-helm/) | **kubectl + Helm** langsung (`helm upgrade --install`) | Deploy cepat/manual, tanpa registrasi pipeline |

Keduanya independen — bisa dipakai salah satu atau berdampingan untuk app yang
berbeda. Baca README masing-masing folder untuk detail lengkap:

- [gke-clouddeploy/README.md](gke-clouddeploy/README.md) — mirror image Nexus→Artifact
  Registry, tarik secret dari Vault, render manifest, lalu `gcloud deploy`.
- [gke-helm/README.md](gke-helm/README.md) — chart Helm (dikonversi dari manifest
  Cloud Deploy), image & secret dianggap sudah siap, deploy via `helm upgrade --install`.

---

## Konsistensi 3 channel

Channel VM/GCE, Cloud Run, dan GKE mengikuti pola yang sama:

- Satu folder template per channel/mekanisme.
- Antarmuka seragam: `./release.sh <app> <tag>` untuk semua channel — Cloud
  Deploy (`gke-clouddeploy/`), Helm (`gke-helm/`), maupun VM/GCE, Cloud Run.
- Konfigurasi terpusat di `.env` per folder.
- Fase mirror Nexus→AR identik pada channel yang memakainya (kecuali VM yang
  bisa pull langsung dari Nexus, dan `gke-helm/` yang mengasumsikan image sudah
  ada di registry).

Simpan sebagai `cd-templates/{gce,cloudrun,gke-clouddeploy,gke-helm}/` di repo standar.
