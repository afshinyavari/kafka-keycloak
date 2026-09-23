{{- /*
=====================================================================
_realm_clients.tpl: client scope "kafka-groups", de enkla klienterna
(Kafka UI, Schema Registry ...) och stubbarna för externa klienter.
=====================================================================
*/ -}}

{{- /*
groupsClientScope: ett client scope med en group membership-mapper som
lägger användarens Keycloak-grupper i claimen "groups". Valfritt även
en mapper som exponerar de råa AD-gruppnamnen från user-attributet.

Keycloak lagrar mapper-config som strängar, även booleans. Därför
"true"/"false" i citattecken och toString på fullPath.
*/ -}}
{{- define "kafka-keycloak-realm.groupsClientScope" -}}
{{- $gc := .Values.groupsClaim -}}
{{- $mappers := list (dict
      "name" $gc.name "protocol" "openid-connect" "protocolMapper" "oidc-group-membership-mapper"
      "config" (dict "claim.name" $gc.name "full.path" (toString $gc.fullPath)
                     "id.token.claim" "true" "access.token.claim" "true" "userinfo.token.claim" "true")) -}}
{{- if $gc.includeAdAttribute -}}
{{- $mappers = append $mappers (dict
      "name" $gc.adAttributeClaim "protocol" "openid-connect" "protocolMapper" "oidc-usermodel-attribute-mapper"
      "config" (dict "user.attribute" .Values.identityProvider.userAttribute "claim.name" $gc.adAttributeClaim
                     "jsonType.label" "String" "multivalued" "true" "aggregate.attrs" "false"
                     "id.token.claim" "true" "access.token.claim" "true" "userinfo.token.claim" "true")) -}}
{{- end -}}
{{- dict "name" "kafka-groups" "protocol" "openid-connect" "description" "Kafka team groups"
         "attributes" (dict "include.in.token.scope" "true" "display.on.consent.screen" "false")
         "protocolMappers" $mappers | toYaml -}}
{{- end -}}

{{- /*
simpleClient: en post ur values "clients" -> en Keycloak-klient.

  * Utan secretEnv blir klienten public (ingen secret alls).
  * defaultClientScopes = clientDefaults.scopes + "kafka-groups". deepCopy
    behövs för att append inte ska ändra listan i .Values för nästa klient.
  * "extra" slås ihop sist med mergeOverwrite och kan skriva över allt.

Argument: (dict "root" $ "client" <posten ur clients>)
*/ -}}
{{- define "kafka-keycloak-realm.simpleClient" -}}
{{- $c := .client -}}
{{- $out := dict "clientId" $c.name "name" $c.name "enabled" true "protocol" "openid-connect"
                 "publicClient" (not $c.secretEnv)
                 "standardFlowEnabled" true "directAccessGrantsEnabled" false
                 "serviceAccountsEnabled" ($c.serviceAccount | default false)
                 "redirectUris" ($c.redirectUris | default list) "webOrigins" (list "+")
                 "defaultClientScopes" (append (deepCopy .root.Values.clientDefaults.scopes) "kafka-groups")
                 "attributes" ($c.attributes | default dict) -}}
{{- if $c.secretEnv }}{{ $_ := set $out "secret" (printf "$(env:%s)" $c.secretEnv) }}{{ end -}}
{{- mergeOverwrite $out (deepCopy ($c.extra | default dict)) | toYaml -}}
{{- end -}}

{{- /*
clients: hela klientlistan i ordningen kafka, enkla klienter, externa stubbar.

Stubben för en extern klient innehåller bara clientId och name.
keycloak-config-cli uppdaterar klienter med patch-semantik, där fält
som saknas lämnas orörda, så stubben bevarar klienten exakt som den är
samtidigt som den inte raderas av import.managed.client=full.
*/ -}}
{{- define "kafka-keycloak-realm.clients" -}}
{{- $clients := list (include "kafka-keycloak-realm.kafkaClient" . | fromYaml) -}}
{{- range $c := .Values.clients | default list -}}
{{- $clients = append $clients (include "kafka-keycloak-realm.simpleClient" (dict "root" $ "client" $c) | fromYaml) -}}
{{- end -}}
{{- range $id := .Values.externalClients | default list -}}
{{- $clients = append $clients (dict "clientId" $id "name" $id) -}}
{{- end -}}
{{- toYaml $clients -}}
{{- end -}}
