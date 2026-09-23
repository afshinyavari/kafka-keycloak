{{- /*
=====================================================================
_helpers.tpl: namn, labels och validering. Inget Kafka-specifikt här.

Filer som börjar med "_" renderas inte till Kubernetes-objekt. De
innehåller bara "define"-block som andra templates anropar med include.
=====================================================================
*/ -}}

{{- define "kafka-keycloak-realm.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- /*
Standardlabels enligt Kubernetes rekommendationer. Den här templaten
returnerar YAML-rader, och anroparen sätter indenteringen med
"include ... | nindent 4".
*/ -}}
{{- define "kafka-keycloak-realm.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | quote }}
app.kubernetes.io/name: {{ include "kafka-keycloak-realm.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- /*
Obligatoriska values. values.schema.json kontrollerar typer, men kan
inte uttrycka "får inte vara tom sträng" på ett läsbart sätt, så det
görs här med "fail" som avbryter renderingen med meddelandet.
*/ -}}
{{- define "kafka-keycloak-realm.validate" -}}
{{- if not .Values.keycloak.url }}{{ fail "keycloak.url is required" }}{{ end -}}
{{- if not .Values.keycloak.existingSecret }}{{ fail "keycloak.existingSecret is required" }}{{ end -}}
{{- if not .Values.realm.name }}{{ fail "realm.name is required" }}{{ end -}}
{{- end -}}
