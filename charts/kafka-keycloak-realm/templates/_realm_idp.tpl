{{- /*
=====================================================================
_realm_idp.tpl: ADFS-providern och dess mappers.

Tre sorters mappers genereras:
  1. En attribute importer som sparar AD-grupperna som user-attribut
     (samma som den befintliga "groups"-mappern).
  2. En "Advanced Claim/Attribute to Group" per team och AD-grupp.
  3. Övriga mappers som kopierats in rått under extraMappers.

OIDC och SAML har olika mapper-typer och olika namn på config-nycklar,
därför finns if/else på providerId på flera ställen.
=====================================================================
*/ -}}

{{- /* identityProviders: en lista med exakt en provider. */ -}}
{{- define "kafka-keycloak-realm.identityProviders" -}}
{{- $idp := .Values.identityProvider -}}
{{- /*
"merge" fyller på första dicten med nycklar från den andra utan att
skriva över befintliga. Så syncMode från values vinner över en eventuell
syncMode inne i den råa config-mappen. deepCopy för att inte mutera .Values.
*/ -}}
{{- $config := merge (dict "syncMode" $idp.syncMode) (deepCopy ($idp.config | default dict)) -}}
{{- $p := dict "alias" $idp.alias "providerId" $idp.providerId "enabled" true "config" $config -}}
{{- if $idp.displayName }}{{ $_ := set $p "displayName" $idp.displayName }}{{ end -}}
{{- list $p | toYaml -}}
{{- end -}}

{{- /*
idpGroupsImporter: mappern som lägger AD-grupperna som user-attribut.
Namnet blir "import-<userAttribute>", till exempel "import-groups".
*/ -}}
{{- define "kafka-keycloak-realm.idpGroupsImporter" -}}
{{- $idp := .Values.identityProvider -}}
{{- $config := dict "syncMode" $idp.syncMode "user.attribute" $idp.userAttribute -}}
{{- $type := "oidc-user-attribute-idp-mapper" -}}
{{- if eq $idp.providerId "saml" -}}
{{- $type = "saml-user-attribute-idp-mapper" -}}
{{- /* SAML-mappern kan matcha på attributets namn ELLER dess friendly name. */ -}}
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

{{- /*
idpGroupMapper: en "Advanced ... to Group"-mapper för ETT team och EN
AD-grupp. Villkoren inne i en sådan mapper är AND, så flera AD-grupper
per team blir flera mappers (OR).

Argument som dict: (dict "root" $ "team" "orders" "adGroup" "AD-Kafka-Orders")
*/ -}}
{{- define "kafka-keycloak-realm.idpGroupMapper" -}}
{{- $idp := .root.Values.identityProvider -}}
{{- $key := $idp.groupsAttribute -}}
{{- if and (eq $idp.providerId "saml") $idp.groupsAttributeFriendlyName }}{{ $key = $idp.groupsAttributeFriendlyName }}{{ end -}}
{{- /*
Keycloak vill ha matchningsvillkoret som en JSON-STRÄNG inuti config,
inte som riktig JSON. Därför toJson här: resultatet blir strängen
[{"key":"groups","value":"AD-Kafka-Orders"}] som Keycloak parsar själv.
Samma trick används för policies i _realm_kafka.tpl.
*/ -}}
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

{{- /*
identityProviderMappers: hela listan. Ordningen är importer, sedan
gruppmappers per team, sedan extraMappers.
*/ -}}
{{- define "kafka-keycloak-realm.identityProviderMappers" -}}
{{- $idp := .Values.identityProvider -}}
{{- $mappers := list (include "kafka-keycloak-realm.idpGroupsImporter" . | fromYaml) -}}
{{- range $name := include "kafka-keycloak-realm.teamNames" . | fromYamlArray -}}
{{- $team := include "kafka-keycloak-realm.team" (dict "root" $ "name" $name) | fromYaml -}}
{{- range $adGroup := $team.adGroups | default list -}}
{{- $mappers = append $mappers (include "kafka-keycloak-realm.idpGroupMapper" (dict "root" $ "team" $name "adGroup" $adGroup) | fromYaml) -}}
{{- end -}}
{{- end -}}
{{- /* extraMappers kopieras rått; bara identityProviderAlias fylls i om det saknas. */ -}}
{{- range $m := $idp.extraMappers | default list -}}
{{- $mappers = append $mappers (merge (dict "identityProviderAlias" $idp.alias) (deepCopy $m)) -}}
{{- end -}}
{{- toYaml $mappers -}}
{{- end -}}
