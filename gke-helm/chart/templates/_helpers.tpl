{{/*
Label standar yang dipasang di semua resource chart ini.

File berawalan garis-bawah TIDAK menghasilkan resource K8s sendiri — isinya
definisi "fungsi" yang dipanggil dari file lain lewat perintah include, diikuti
sebuah titik sebagai argumen. Titik itu "konteks" yang diteruskan, supaya
fungsi ini bisa akses .Values/.Chart/.Release milik pemanggilnya.

Dipanggil dari: deployment.yaml, service.yaml, hpa.yaml, ingress.yaml,
configmap.yaml. Kalau nanti mau tambah label standar baru, cukup ubah SATU
TEMPAT INI — otomatis ikut ke kelima file itu, tidak perlu copy-paste manual.

Blok komentar seperti ini (dibuka slash-asterisk, ditutup asterisk-slash)
dihapus total saat Helm render — beda dari komentar pagar (#) YAML biasa
yang tetap boleh muncul di YAML final.
*/}}
{{- define "gke-app.labels" -}}
app: {{ .Values.appName }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
