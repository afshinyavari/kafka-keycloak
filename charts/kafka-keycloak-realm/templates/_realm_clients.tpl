{{/*
Client scope that puts the user's groups into tokens.
*/}}
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

{{/*
One simple OIDC client. Usage: include "kafka-keycloak-realm.simpleClient" (dict "root" $ "client" $c)
*/}}
{{- define "kafka-keycloak-realm.simpleClient" -}}
{{- $c := .client -}}
{{- $out := dict "clientId" $c.name "name" $c.name "enabled" true "protocol" "openid-connect"
                 "publicClient" (not $c.secretEnv)
                 "standardFlowEnabled" true "directAccessGrantsEnabled" false
                 "serviceAccountsEnabled" ($c.serviceAccount | default false)
                 "redirectUris" ($c.redirectUris | default list) "webOrigins" (list "+")
                 "defaultClientScopes" (list "profile" "email" "roles" "web-origins" "kafka-groups")
                 "attributes" ($c.attributes | default dict) -}}
{{- if $c.secretEnv }}{{ $_ := set $out "secret" (printf "$(env:%s)" $c.secretEnv) }}{{ end -}}
{{- mergeOverwrite $out (deepCopy ($c.extra | default dict)) | toYaml -}}
{{- end -}}

{{/*
All clients: kafka, simple clients, external stubs.
*/}}
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
