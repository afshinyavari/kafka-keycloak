{{- /*
=====================================================================
_realm_kafka.tpl: klienten "kafka" och dess authorization settings.

Det här är chartens kärna. Flödet i kafkaAuthz är:

  för varje team
    -> en group-policy "team:<team>"
    för varje grant (owns räknas som första grant)
      slå upp rollprofilen
      för varje (resurstyp, mönster) i granten
        om profilen har scopes för typen:
          -> registrera resursen (dedupliceras via dict-nyckel)
          -> en scope-permission "<team> / <roll> / <resurs>"

Keycloak lägger permissions i samma "policies"-lista som policies,
skillnaden är fältet "type" (group respektive scope).
=====================================================================
*/ -}}

{{- /*
roleProfile: rollprofilen (scopes per resurstyp) för ett rollnamn.
Det syntetiska namnet "all" ger alla scopes på alla typer och används
bara av cluster-admins. Okänd roll ger ett tydligt renderingsfel via
"fail", som är sättet att avbryta helm template med ett meddelande.

Argument: (dict "root" $ "role" "topic-owner")
*/ -}}
{{- define "kafka-keycloak-realm.roleProfile" -}}
{{- if eq .role "all" -}}
{{- $all := .root.Values.kafka.scopes -}}
{{- dict "topic" $all "group" $all "transactionalId" $all "cluster" $all | toYaml -}}
{{- else -}}
{{- /* "get" på en dict returnerar tom sträng om nyckeln saknas, vilket "not" fångar. */ -}}
{{- $profile := get (.root.Values.roles | default dict) .role -}}
{{- if not $profile }}{{ fail (printf "grant references unknown role %q: define it under roles" .role) }}{{ end -}}
{{- toYaml $profile -}}
{{- end -}}
{{- end -}}

{{- /*
teamGrants: teamets effektiva grants som YAML-lista.

  * "owns" blir första granten med rollen ownership.role. Nycklarna i
    owns (topics, consumerGroups, transactionalIds) är samma som i en
    grant, så det räcker att lägga till "role".
  * därefter teamets explicita grants oförändrade.
  * cluster-admins får en enda syntetisk grant på allt.

Argument: (dict "root" $ "name" "orders")
*/ -}}
{{- define "kafka-keycloak-realm.teamGrants" -}}
{{- $grants := list -}}
{{- if eq .name "cluster-admins" -}}
{{- $grants = list (dict "role" "all" "topics" (list "*") "consumerGroups" (list "*") "transactionalIds" (list "*") "cluster" true) -}}
{{- else -}}
{{- /* "." är redan (dict "root" $ "name" ...) här, så den kan skickas vidare som den är. */ -}}
{{- $team := include "kafka-keycloak-realm.team" . | fromYaml -}}
{{- if $team.owns -}}
{{- $grants = append $grants (merge (dict "role" .root.Values.ownership.role) (deepCopy $team.owns)) -}}
{{- end -}}
{{- range $g := $team.grants | default list }}{{ $grants = append $grants $g }}{{ end -}}
{{- end -}}
{{- toYaml $grants -}}
{{- end -}}

{{- /*
resourceName: "Topic:orders.*", eller med kafka.clusterName satt
"kafka-cluster:my-cluster,Topic:orders.*". Det senare är Strimzis
format för att skilja kluster åt i samma realm.

Detta är den enda template som returnerar ren text i stället för YAML.
*/ -}}
{{- define "kafka-keycloak-realm.resourceName" -}}
{{- if .root.Values.kafka.clusterName }}kafka-cluster:{{ .root.Values.kafka.clusterName }},{{ end }}{{ .type }}:{{ .pattern }}
{{- end -}}

{{- /* kafkaAuthz: hela authorizationSettings-blocket. Anropas med "." (roten). */ -}}
{{- define "kafka-keycloak-realm.kafkaAuthz" -}}
{{- /*
Spara roten i $root. Inne i "range" nedan pekar "." på listelementet,
och "$" fungerar visserligen också, men $root är tydligare att läsa.
*/ -}}
{{- $root := . -}}

{{- $ownRole := .Values.ownership.role -}}
{{- if not (hasKey (.Values.roles | default dict) $ownRole) }}{{ fail (printf "ownership.role %q is not defined under roles" $ownRole) }}{{ end -}}

{{- /* Keycloak vill ha scopes som [{name: Read}, {name: Write}, ...], inte som strängar. */ -}}
{{- $allScopes := list }}{{ range .Values.kafka.scopes }}{{ $allScopes = append $allScopes (dict "name" .) }}{{ end -}}

{{- /*
Tabell som kopplar ihop tre namn för varje resurstyp:
  key:  nyckeln i en grant/owns i values      (topics)
  type: Keycloak/Strimzi-resurstypen          (Topic)
  role: nyckeln i en rollprofil               (topic)
Cluster hanteras separat eftersom den inte har mönster, bara "*".
*/ -}}
{{- $types := list
      (dict "key" "topics" "type" "Topic" "role" "topic")
      (dict "key" "consumerGroups" "type" "Group" "role" "group")
      (dict "key" "transactionalIds" "type" "TransactionalId" "role" "transactionalId") -}}

{{- /*
$resources är en dict med resursnamnet som nyckel. Att sätta samma
nyckel två gånger skriver bara över, vilket ger dedupliceringen gratis
när två team refererar samma topic.
*/ -}}
{{- $resources := dict -}}
{{- $policies := list -}}
{{- $permissions := list -}}

{{- range $name := include "kafka-keycloak-realm.teamNames" . | fromYamlArray -}}
{{- $policyName := printf "team:%s" $name -}}
{{- $path := include "kafka-keycloak-realm.groupPath" (dict "root" $root "name" $name) -}}

{{- /*
Group-policyn. "config.groups" måste vara en JSON-sträng (se
_realm_idp.tpl), därav toJson. keycloak-config-cli slår själv upp
gruppens id från "path".
*/ -}}
{{- $policies = append $policies (dict
      "name" $policyName "type" "group" "logic" "POSITIVE" "decisionStrategy" "UNANIMOUS"
      "config" (dict "groups" (list (dict "path" $path "extendChildren" false) | toJson))) -}}

{{- range $grant := include "kafka-keycloak-realm.teamGrants" (dict "root" $root "name" $name) | fromYamlArray -}}
{{- $profile := include "kafka-keycloak-realm.roleProfile" (dict "root" $root "role" $grant.role) | fromYaml -}}

{{- /*
Först plattas granten ut till en lista av mål: (typ, mönster, scopes).
"get $grant $t.key" ger tom sträng om nyckeln saknas, "default list"
gör den till en tom lista så att range fungerar.
*/ -}}
{{- $targets := list -}}
{{- range $t := $types -}}
{{- range $pattern := get $grant $t.key | default list -}}
{{- $targets = append $targets (dict "type" $t.type "pattern" $pattern "scopes" (get $profile $t.role)) -}}
{{- end -}}
{{- end -}}
{{- if $grant.cluster }}{{ $targets = append $targets (dict "type" "Cluster" "pattern" "*" "scopes" $profile.cluster) }}{{ end -}}

{{- /*
Sedan blir varje mål en resurs och en permission. Saknar profilen
scopes för typen (t.ex. topic-reader utan transactionalId) hoppas
målet över helt, så inga oanvända resurser skapas.
*/ -}}
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

{{- /* Dict -> sorterad lista, så att utdatan är stabil mellan körningar. */ -}}
{{- $resourceList := list }}{{ range $k := keys $resources | sortAlpha }}{{ $resourceList = append $resourceList (get $resources $k) }}{{ end -}}

{{- dict "allowRemoteResourceManagement" false
         "policyEnforcementMode" "ENFORCING"
         "decisionStrategy" .Values.kafka.decisionStrategy
         "scopes" $allScopes
         "resources" $resourceList
         "policies" (concat $policies $permissions) | toYaml -}}
{{- end -}}

{{- /*
kafkaClient: själva klienten. Ingen inloggning via browser
(standardFlowEnabled: false), bara service account plus authorization
services, vilket är vad Strimzis KeycloakAuthorizer behöver.
Secreten är en $(env:...)-referens som keycloak-config-cli byter ut.
*/ -}}
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
