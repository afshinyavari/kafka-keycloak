{{/*
Builds the realm representation as a dict and renders it as YAML.
*/}}
{{- define "kafka-keycloak-realm.realm" -}}
{{- include "kafka-keycloak-realm.validate" . -}}
{{- $realm := dict "realm" .Values.realm.name "enabled" true -}}
{{- if .Values.realm.displayName }}{{ $_ := set $realm "displayName" .Values.realm.displayName }}{{ end -}}
{{- $realm = mergeOverwrite $realm (deepCopy (.Values.realm.settings | default dict)) -}}
{{- $_ := set $realm "groups" (include "kafka-keycloak-realm.groups" . | fromYamlArray) -}}
{{- if .Values.identityProvider.enabled -}}
{{- $_ := set $realm "identityProviders" (include "kafka-keycloak-realm.identityProviders" . | fromYamlArray) -}}
{{- $_ := set $realm "identityProviderMappers" (include "kafka-keycloak-realm.identityProviderMappers" . | fromYamlArray) -}}
{{- end -}}
{{- $_ := set $realm "clientScopes" (list (include "kafka-keycloak-realm.groupsClientScope" . | fromYaml)) -}}
{{- $_ := set $realm "clients" (include "kafka-keycloak-realm.clients" . | fromYamlArray) -}}
{{- $realm = mergeOverwrite $realm (deepCopy (.Values.extraRealm | default dict)) -}}
{{- toYaml $realm -}}
{{- end -}}
