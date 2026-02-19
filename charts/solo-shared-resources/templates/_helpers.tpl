{{/* vim: set filetype=mustache: */}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "solo-shared-resources.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Constructs the database name.
*/}}

{{/*
Selector labels
*/}}
{{- define "solo-shared-resources.selectorLabels" -}}
app.kubernetes.io/component: solo-shared-resource
app.kubernetes.io/name: {{ .Release.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Constructs the database host that should be used by all components.
*/}}
{{- define "solo-shared-resources.db" -}}
{{- if .Values.db.host -}}
{{- tpl .Values.db.host . -}}
{{- else if and .Values.postgresql.enabled (gt (.Values.postgresql.pgpool.replicaCount | int) 0) -}}
{{- include "postgresql-ha.pgpool" .Subcharts.postgresql -}}
{{- else if .Values.postgresql.enabled -}}
{{- include "postgresql-ha.postgresql" .Subcharts.postgresql -}}
{{- end -}}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "solo-shared-resources.labels" -}}
{{ include "solo-shared-resources.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: solo-shared-resources-node
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ include "solo-shared-resources.chart" . }}
{{- if .Values.labels }}
{{ toYaml .Values.labels }}
{{- end }}
{{- end -}}

{{/*
Namespace
*/}}
{{- define "solo-shared-resources.namespace" -}}
{{- .Release.Namespace -}}
{{- end -}}
