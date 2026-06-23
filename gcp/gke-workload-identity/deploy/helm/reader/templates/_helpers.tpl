{{- define "reader.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "reader.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "reader.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "reader.labels" -}}
app.kubernetes.io/name: {{ include "reader.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
