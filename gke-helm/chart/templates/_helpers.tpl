{{/*
Label standar yang dipasang di semua resource chart ini.
*/}}
{{- define "gke-app.labels" -}}
app: {{ .Values.appName }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
