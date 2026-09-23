{{- /*
=====================================================================
_realm.tpl: sätter ihop hela realm-representationen.

Läs docs/helm-templates.md först om Go-templates känns främmande.

Grundidén i alla _realm_*.tpl-filer är densamma:

  1. Bygg upp datan som en dict (map) och listor med Sprig-funktionerna
     dict, set, list och append, i stället för att skriva YAML-text.
  2. Serialisera med toYaml i slutet.

Det gör att indentering aldrig blir ett problem, att nycklarna alltid
sorteras deterministiskt, och att en rå "extraRealm" kan slås ihop med
det genererade resultatet med mergeOverwrite.

En "define" kan bara returnera text, aldrig en dict. Därför returnerar
varje del-template YAML-text, och anroparen gör "include ... | fromYaml"
(eller fromYamlArray för listor) för att få tillbaka datan.
=====================================================================
*/ -}}

{{- define "kafka-keycloak-realm.realm" -}}
{{- /* Stoppa tidigt med tydligt fel om obligatoriska values saknas. */ -}}
{{- include "kafka-keycloak-realm.validate" . -}}

{{- /* Starta med realmens grundfält. "dict" tar nyckel/värde-par växelvis. */ -}}
{{- $realm := dict "realm" .Values.realm.name "enabled" true -}}

{{- /*
"set" lägger till en nyckel i en befintlig dict. Den returnerar dicten,
och Go-templates skriver ut returvärden, så vi fångar det i den
meningslösa variabeln $_ för att inte få skräp i utdatan.
*/ -}}
{{- if .Values.realm.displayName }}{{ $_ := set $realm "displayName" .Values.realm.displayName }}{{ end -}}

{{- /*
Råa realm-inställningar från values läggs ovanpå. deepCopy skyddar
.Values från att muteras, eftersom mergeOverwrite ändrar sitt första
argument på plats.
*/ -}}
{{- $realm = mergeOverwrite $realm (deepCopy (.Values.realm.settings | default dict)) -}}

{{- /* Varje del byggs i sin egen fil och hämtas in som YAML-text -> data. */ -}}
{{- $_ := set $realm "groups" (include "kafka-keycloak-realm.groups" . | fromYamlArray) -}}

{{- if .Values.identityProvider.enabled -}}
{{- $_ := set $realm "identityProviders" (include "kafka-keycloak-realm.identityProviders" . | fromYamlArray) -}}
{{- $_ := set $realm "identityProviderMappers" (include "kafka-keycloak-realm.identityProviderMappers" . | fromYamlArray) -}}
{{- end -}}

{{- $_ := set $realm "clientScopes" (list (include "kafka-keycloak-realm.groupsClientScope" . | fromYaml)) -}}
{{- $_ := set $realm "clients" (include "kafka-keycloak-realm.clients" . | fromYamlArray) -}}

{{- /*
Ventilen: allt under extraRealm i values slås ihop sist och vinner.
Observera att listor ersätts helt, de slås inte ihop.
*/ -}}
{{- $realm = mergeOverwrite $realm (deepCopy (.Values.extraRealm | default dict)) -}}

{{- /* Slutresultatet som YAML-text. configmap.yaml indenterar den. */ -}}
{{- toYaml $realm -}}
{{- end -}}
