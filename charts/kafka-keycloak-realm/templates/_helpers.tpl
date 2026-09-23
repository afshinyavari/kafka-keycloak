{{/*
Common naming helpers.
*/}}
{{- define "kafka-keycloak-realm.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "kafka-keycloak-realm.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "kafka-keycloak-realm.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | quote }}
app.kubernetes.io/name: {{ include "kafka-keycloak-realm.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "kafka-keycloak-realm.validate" -}}
{{- if not .Values.keycloak.url }}{{ fail "keycloak.url is required" }}{{ end -}}
{{- if not .Values.keycloak.existingSecret }}{{ fail "keycloak.existingSecret is required" }}{{ end -}}
{{- if not .Values.realm.name }}{{ fail "realm.name is required" }}{{ end -}}
{{- end -}}
