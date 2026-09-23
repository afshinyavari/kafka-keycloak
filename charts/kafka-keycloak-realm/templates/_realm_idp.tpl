{{/*
Identity provider list (single provider).
*/}}
{{- define "kafka-keycloak-realm.identityProviders" -}}
{{- $idp := .Values.identityProvider -}}
{{- $config := merge (dict "syncMode" $idp.syncMode) (deepCopy ($idp.config | default dict)) -}}
{{- $p := dict "alias" $idp.alias "providerId" $idp.providerId "enabled" true "config" $config -}}
{{- if $idp.displayName }}{{ $_ := set $p "displayName" $idp.displayName }}{{ end -}}
{{- list $p | toYaml -}}
{{- end -}}

{{/*
Attribute importer that stores the AD groups as a user attribute.
*/}}
{{- define "kafka-keycloak-realm.idpGroupsImporter" -}}
{{- $idp := .Values.identityProvider -}}
{{- $config := dict "syncMode" $idp.syncMode "user.attribute" $idp.userAttribute -}}
{{- $type := "oidc-user-attribute-idp-mapper" -}}
{{- if eq $idp.providerId "saml" -}}
{{- $type = "saml-user-attribute-idp-mapper" -}}
{{- if $idp.groupsAttributeFriendlyName -}}
{{- $_ := set $config "attribute.friendly.name" $idp.groupsAttributeFriendlyName -}}
{{- else -}}
{{- $_ := set $config "attribute.name" $idp.groupsAttribute -}}
{{- end -}}
{{- else -}}
{{- $_ := set $config "claim" $idp.groupsAttribute -}}
{{- end -}}
{{- dict "name" (printf "import-%s" $idp.userAttribute) "identityProviderAlias" $idp.alias "identityProviderMapper" $type "config" $config | toYaml -}}
{{- end -}}

{{/*
Advanced attribute/claim to group mapper for one team and one AD group.
Usage: include "kafka-keycloak-realm.idpGroupMapper" (dict "root" $ "team" "orders" "adGroup" "AD-X")
*/}}
{{- define "kafka-keycloak-realm.idpGroupMapper" -}}
{{- $idp := .root.Values.identityProvider -}}
{{- $key := $idp.groupsAttribute -}}
{{- if and (eq $idp.providerId "saml") $idp.groupsAttributeFriendlyName }}{{ $key = $idp.groupsAttributeFriendlyName }}{{ end -}}
{{- $match := list (dict "key" $key "value" .adGroup) | toJson -}}
{{- $config := dict "syncMode" $idp.syncMode "group" (include "kafka-keycloak-realm.groupPath" (dict "root" .root "name" .team)) -}}
{{- $type := "oidc-advanced-group-idp-mapper" -}}
{{- if eq $idp.providerId "saml" -}}
{{- $type = "saml-advanced-group-idp-mapper" -}}
{{- $_ := set $config "attributes" $match -}}
{{- $_ := set $config "are.attribute.values.regex" "false" -}}
{{- else -}}
{{- $_ := set $config "claims" $match -}}
{{- $_ := set $config "are.claim.values.regex" "false" -}}
{{- end -}}
{{- dict "name" (printf "team:%s <- %s" .team .adGroup) "identityProviderAlias" $idp.alias "identityProviderMapper" $type "config" $config | toYaml -}}
{{- end -}}

{{/*
All identity provider mappers: importer, one group mapper per team/AD group, extra mappers.
*/}}
{{- define "kafka-keycloak-realm.identityProviderMappers" -}}
{{- $idp := .Values.identityProvider -}}
{{- $mappers := list (include "kafka-keycloak-realm.idpGroupsImporter" . | fromYaml) -}}
{{- range $name := include "kafka-keycloak-realm.teamNames" . | fromYamlArray -}}
{{- $team := include "kafka-keycloak-realm.team" (dict "root" $ "name" $name) | fromYaml -}}
{{- range $adGroup := $team.adGroups | default list -}}
{{- $mappers = append $mappers (include "kafka-keycloak-realm.idpGroupMapper" (dict "root" $ "team" $name "adGroup" $adGroup) | fromYaml) -}}
{{- end -}}
{{- end -}}
{{- range $m := $idp.extraMappers | default list -}}
{{- $mappers = append $mappers (merge (dict "identityProviderAlias" $idp.alias) (deepCopy $m)) -}}
{{- end -}}
{{- toYaml $mappers -}}
{{- end -}}
