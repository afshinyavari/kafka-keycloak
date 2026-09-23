{{/*
Role profile by name. The synthetic profile "all" grants every scope on every type.
Usage: include "kafka-keycloak-realm.roleProfile" (dict "root" $ "role" "topic-owner") | fromYaml
*/}}
{{- define "kafka-keycloak-realm.roleProfile" -}}
{{- if eq .role "all" -}}
{{- $all := .root.Values.kafka.scopes -}}
{{- dict "topic" $all "group" $all "transactionalId" $all "cluster" $all | toYaml -}}
{{- else -}}
{{- $profile := get (.root.Values.roles | default dict) .role -}}
{{- if not $profile }}{{ fail (printf "grant references unknown role %q: define it under roles" .role) }}{{ end -}}
{{- toYaml $profile -}}
{{- end -}}
{{- end -}}

{{/*
Effective grants for a team: "owns" first (with ownership.role), then explicit grants.
cluster-admins gets a single synthetic grant on everything.
*/}}
{{- define "kafka-keycloak-realm.teamGrants" -}}
{{- $grants := list -}}
{{- if eq .name "cluster-admins" -}}
{{- $grants = list (dict "role" "all" "topics" (list "*") "consumerGroups" (list "*") "transactionalIds" (list "*") "cluster" true) -}}
{{- else -}}
{{- $team := include "kafka-keycloak-realm.team" . | fromYaml -}}
{{- if $team.owns -}}
{{- $grants = append $grants (merge (dict "role" .root.Values.ownership.role) (deepCopy $team.owns)) -}}
{{- end -}}
{{- range $g := $team.grants | default list }}{{ $grants = append $grants $g }}{{ end -}}
{{- end -}}
{{- toYaml $grants -}}
{{- end -}}

{{- define "kafka-keycloak-realm.resourceName" -}}
{{- if .root.Values.kafka.clusterName }}kafka-cluster:{{ .root.Values.kafka.clusterName }},{{ end }}{{ .type }}:{{ .pattern }}
{{- end -}}

{{/*
authorizationSettings for the kafka client: scopes, resources, group policies and scope permissions.
*/}}
{{- define "kafka-keycloak-realm.kafkaAuthz" -}}
{{- $root := . -}}
{{- $ownRole := .Values.ownership.role -}}
{{- if not (hasKey (.Values.roles | default dict) $ownRole) }}{{ fail (printf "ownership.role %q is not defined under roles" $ownRole) }}{{ end -}}
{{- $allScopes := list }}{{ range .Values.kafka.scopes }}{{ $allScopes = append $allScopes (dict "name" .) }}{{ end -}}
{{- $types := list
      (dict "key" "topics" "type" "Topic" "role" "topic")
      (dict "key" "consumerGroups" "type" "Group" "role" "group")
      (dict "key" "transactionalIds" "type" "TransactionalId" "role" "transactionalId") -}}
{{- $resources := dict -}}
{{- $policies := list -}}
{{- $permissions := list -}}
{{- range $name := include "kafka-keycloak-realm.teamNames" . | fromYamlArray -}}
{{- $policyName := printf "team:%s" $name -}}
{{- $path := include "kafka-keycloak-realm.groupPath" (dict "root" $root "name" $name) -}}
{{- $policies = append $policies (dict
      "name" $policyName "type" "group" "logic" "POSITIVE" "decisionStrategy" "UNANIMOUS"
      "config" (dict "groups" (list (dict "path" $path "extendChildren" false) | toJson))) -}}
{{- range $grant := include "kafka-keycloak-realm.teamGrants" (dict "root" $root "name" $name) | fromYamlArray -}}
{{- $profile := include "kafka-keycloak-realm.roleProfile" (dict "root" $root "role" $grant.role) | fromYaml -}}
{{- $targets := list -}}
{{- range $t := $types -}}
{{- range $pattern := get $grant $t.key | default list -}}
{{- $targets = append $targets (dict "type" $t.type "pattern" $pattern "scopes" (get $profile $t.role)) -}}
{{- end -}}
{{- end -}}
{{- if $grant.cluster }}{{ $targets = append $targets (dict "type" "Cluster" "pattern" "*" "scopes" $profile.cluster) }}{{ end -}}
{{- range $target := $targets -}}
{{- if $target.scopes -}}
{{- $rname := include "kafka-keycloak-realm.resourceName" (dict "root" $root "type" $target.type "pattern" $target.pattern) -}}
{{- $_ := set $resources $rname (dict "name" $rname "type" $target.type "scopes" $allScopes) -}}
{{- $permissions = append $permissions (dict
      "name" (printf "%s / %s / %s" $name $grant.role $rname) "type" "scope" "logic" "POSITIVE" "decisionStrategy" "UNANIMOUS"
      "config" (dict "resources" (list $rname | toJson) "scopes" (toJson $target.scopes) "applyPolicies" (list $policyName | toJson))) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $resourceList := list }}{{ range $k := keys $resources | sortAlpha }}{{ $resourceList = append $resourceList (get $resources $k) }}{{ end -}}
{{- dict "allowRemoteResourceManagement" false
         "policyEnforcementMode" "ENFORCING"
         "decisionStrategy" .Values.kafka.decisionStrategy
         "scopes" $allScopes
         "resources" $resourceList
         "policies" (concat $policies $permissions) | toYaml -}}
{{- end -}}

{{- define "kafka-keycloak-realm.kafkaClient" -}}
{{- dict "clientId" .Values.kafka.clientId
         "name" .Values.kafka.clientId
         "enabled" true
         "protocol" "openid-connect"
         "publicClient" false
         "secret" (printf "$(env:%s)" .Values.kafka.secretEnv)
         "serviceAccountsEnabled" true
         "authorizationServicesEnabled" true
         "standardFlowEnabled" false
         "directAccessGrantsEnabled" false
         "authorizationSettings" (include "kafka-keycloak-realm.kafkaAuthz" . | fromYaml) | toYaml -}}
{{- end -}}
