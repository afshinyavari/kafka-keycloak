{{- /*
=====================================================================
_realm_groups.tpl: team-listan och Keycloak-grupperna.

Här finns också de hjälp-templates som resten av charten använder för
att iterera över team: teamNames, team och groupPath.
=====================================================================
*/ -}}

{{- /*
teamNames: alla teamnamn som en sorterad YAML-lista, plus det syntetiska
teamet "cluster-admins" om clusterAdmins.adGroups är satt.

Team som satts till null i en miljöfil hoppas över. "kindIs map" är
sättet att fråga "är detta en dict?" i Sprig.

Anropas med "." som context (hela roten), så .Values fungerar direkt.
*/ -}}
{{- define "kafka-keycloak-realm.teamNames" -}}
{{- $names := list -}}
{{- range $name, $team := .Values.teams | default dict -}}
{{- if kindIs "map" $team }}{{ $names = append $names $name }}{{ end -}}
{{- end -}}
{{- $names = sortAlpha $names -}}
{{- if .Values.clusterAdmins.adGroups }}{{ $names = append $names "cluster-admins" }}{{ end -}}
{{- toYaml $names -}}
{{- end -}}

{{- /*
team: ett teams definition som YAML, givet dess namn. Det syntetiska
teamet cluster-admins får en definition byggd från clusterAdmins.

Den här templaten anropas INTE med "." utan med en egen liten dict:

    include "kafka-keycloak-realm.team" (dict "root" $ "name" "orders")

Det är mönstret för att skicka flera argument till en template: packa
dem i en dict. "root" är hela chart-contexten ($) så att .Values går
att nå som .root.Values.
*/ -}}
{{- define "kafka-keycloak-realm.team" -}}
{{- if eq .name "cluster-admins" -}}
{{- dict "description" "Kafka cluster administrators" "adGroups" .root.Values.clusterAdmins.adGroups | toYaml -}}
{{- else -}}
{{- get .root.Values.teams .name | default dict | toYaml -}}
{{- end -}}
{{- end -}}

{{- /* groupPath: "/kafka/orders" för teamet orders. Samma dict-argument som ovan. */ -}}
{{- define "kafka-keycloak-realm.groupPath" -}}
{{- printf "/%s/%s" .root.Values.groups.parent .name -}}
{{- end -}}

{{- /*
groups: Keycloaks "groups"-lista. En föräldragrupp med en subgrupp per team.

Inne i "range" byter "." betydelse till listelementet, därför används
"$" (roten) när vi behöver .Values där.
*/ -}}
{{- define "kafka-keycloak-realm.groups" -}}
{{- $subGroups := list -}}
{{- range $name := include "kafka-keycloak-realm.teamNames" . | fromYamlArray -}}
{{- $team := include "kafka-keycloak-realm.team" (dict "root" $ "name" $name) | fromYaml -}}
{{- $g := dict "name" $name -}}
{{- /* Keycloak lagrar gruppattribut som listor av strängar, därav "list". */ -}}
{{- if $team.description }}{{ $_ := set $g "attributes" (dict "description" (list $team.description)) }}{{ end -}}
{{- /*
"append" returnerar en NY lista, så resultatet måste tilldelas tillbaka.
Tilldelning med "=" (inte ":=") krävs inne i range för att den yttre
variabeln ska uppdateras och inte en ny lokal skapas.
*/ -}}
{{- $subGroups = append $subGroups $g -}}
{{- end -}}
{{- list (dict "name" .Values.groups.parent "subGroups" $subGroups) | toYaml -}}
{{- end -}}
