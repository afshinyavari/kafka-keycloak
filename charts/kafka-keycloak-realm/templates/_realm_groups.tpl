{{/*
Team names as a sorted list, including the synthetic cluster-admins team when enabled.
Returns YAML list.
*/}}
{{- define "kafka-keycloak-realm.teamNames" -}}
{{- $names := keys (.Values.teams | default dict) | sortAlpha -}}
{{- if .Values.clusterAdmins.adGroups }}{{ $names = append $names "cluster-admins" }}{{ end -}}
{{- toYaml $names -}}
{{- end -}}

{{/*
Team definition by name, resolving the synthetic cluster-admins team.
Usage: include "kafka-keycloak-realm.team" (dict "root" $ "name" "orders") | fromYaml
*/}}
{{- define "kafka-keycloak-realm.team" -}}
{{- if eq .name "cluster-admins" -}}
{{- dict "description" "Kafka cluster administrators" "adGroups" .root.Values.clusterAdmins.adGroups | toYaml -}}
{{- else -}}
{{- get .root.Values.teams .name | default dict | toYaml -}}
{{- end -}}
{{- end -}}

{{- define "kafka-keycloak-realm.groupPath" -}}
{{- printf "/%s/%s" .root.Values.groups.parent .name -}}
{{- end -}}

{{/*
The groups list: one parent with a subgroup per team.
*/}}
{{- define "kafka-keycloak-realm.groups" -}}
{{- $subGroups := list -}}
{{- range $name := include "kafka-keycloak-realm.teamNames" . | fromYamlArray -}}
{{- $team := include "kafka-keycloak-realm.team" (dict "root" $ "name" $name) | fromYaml -}}
{{- $g := dict "name" $name -}}
{{- if $team.description }}{{ $_ := set $g "attributes" (dict "description" (list $team.description)) }}{{ end -}}
{{- $subGroups = append $subGroups $g -}}
{{- end -}}
{{- list (dict "name" .Values.groups.parent "subGroups" $subGroups) | toYaml -}}
{{- end -}}
