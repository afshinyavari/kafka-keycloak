# Så fungerar chartens templates

Den här guiden förklarar de idiom som `.tpl`-filerna i
`charts/kafka-keycloak-realm/templates/` bygger på. Varje fil har dessutom
kommentarer inline. Läs den här sidan först, sedan filerna i ordningen
`_realm.tpl`, `_realm_groups.tpl`, `_realm_kafka.tpl`.

## Varför inte bara skriva YAML?

Vanliga Helm-charts skriver YAML-text med `{{ .Values.x }}` insprängt. Det
fungerar för en Deployment, men realm-filen är djupt nästlad, listor byggs
ur andra listor, och samma topic kan refereras av flera team. Att hålla
indentering och deduplicering rätt i textform är hopplöst.

Därför bygger charten datan som **dicts och listor** med Sprig-funktioner och
serialiserar med `toYaml` i slutet. Det ser ovant ut men är i grunden vanlig
programmering: skapa en map, lägg till nycklar, loopa, lägg till i en lista.

## De fem idiomen

### 1. `define` och `include`: funktioner som returnerar text

```
{{- define "kafka-keycloak-realm.groupPath" -}}
{{- printf "/%s/%s" .root.Values.groups.parent .name -}}
{{- end -}}
```

Ett `define`-block är en funktion. Den anropas med `include "namn" argument`.
Det enda den kan returnera är **text**. Det leder direkt till idiom 2.

Bindestrecken i `{{-` och `-}}` tar bort whitespace runt taggen. I dessa
filer står de överallt, så att ingen radbrytning läcker ut i resultatet.

### 2. `toYaml` ut, `fromYaml` in: skicka data mellan templates

Eftersom en template bara kan returnera text, serialiseras datan till YAML
på väg ut och parsas tillbaka på väg in:

```
{{- $team := include "kafka-keycloak-realm.team" (dict "root" $ "name" $name) | fromYaml -}}
```

`fromYaml` ger en dict, `fromYamlArray` ger en lista. Det kostar lite
prestanda men gör att varje del kan byggas och testas för sig.

### 3. `dict`, `set`, `list`, `append`: bygga data

```
{{- $g := dict "name" $name -}}                       {{/* {name: orders} */}}
{{- $_ := set $g "attributes" (dict "x" "y") -}}      {{/* lägg till nyckel */}}
{{- $subGroups = append $subGroups $g -}}             {{/* lägg till i lista */}}
```

Två fällor:

- `set` **returnerar** dicten, och allt som returneras i en template skrivs
  ut. Därför fångas returvärdet i `$_`, en variabel som ignoreras.
- `append` returnerar en **ny** lista. Resultatet måste tilldelas tillbaka
  med `=`. Inne i `range` måste det vara `=` och inte `:=`, annars skapas
  en ny lokal variabel och den yttre listan förblir tom.

Dicts är också ett enkelt sätt att deduplicera: sätt samma nyckel två gånger
och den finns bara en gång. Så hanteras resurser i `_realm_kafka.tpl`.

### 4. Flera argument: packa dem i en dict

En template tar exakt ett argument, som blir `.` inuti. För att skicka flera
saker packas de i en dict:

```
{{- include "kafka-keycloak-realm.idpGroupMapper" (dict "root" $ "team" $name "adGroup" $adGroup) -}}
```

Inuti templaten nås de som `.root`, `.team`, `.adGroup`. `.root` är hela
chart-contexten, alltså det som `.` är i en vanlig template, så att
`.root.Values.x` fungerar.

Templates som anropas med `.` direkt, till exempel `kafkaAuthz`, använder
`.Values` som vanligt. Vilken sort en template är står i dess kommentar.

Inne i `range` byter `.` betydelse till det aktuella elementet. `$` pekar
alltid på roten, oavsett hur djupt man är. Därför förekommer `$` och
`$root` i loopar.

### 5. `toJson` för Keycloaks strängade config

Keycloak lagrar viss config som **JSON inuti en sträng**, till exempel vilka
grupper en policy gäller:

```yaml
config:
  groups: '[{"path":"/kafka/orders","extendChildren":false}]'
```

Det uppnås med `toJson` på en dict eller lista. Resultatet är en sträng, och
`toYaml` citerar den. Samma sak gäller `claims`/`attributes` i IdP-mappers
och `resources`/`scopes`/`applyPolicies` i permissions.

## Övriga funktioner som förekommer

| Funktion | Betydelse |
|---|---|
| `merge a b` | Fyll på `a` med nycklar från `b` utan att skriva över befintliga. Muterar `a`. |
| `mergeOverwrite a b` | Som merge, men `b` vinner. Listor ersätts, slås inte ihop. |
| `deepCopy x` | Kopia, så att merge/append inte muterar `.Values`. |
| `get d "k"` | Hämta nyckel ur dict. Tom sträng om nyckeln saknas. |
| `hasKey d "k"` | Finns nyckeln? |
| `kindIs "map" x` | Är x en dict? Används för att hoppa över team som satts till `null`. |
| `default x y` | `y` om det är satt, annars `x`. Ofta som `... \| default list`. |
| `keys d \| sortAlpha` | Dictens nycklar sorterade, för stabil utdata. |
| `concat a b` | Två listor efter varandra. |
| `printf` | Som i C. `%q` citerar strängen i felmeddelanden. |
| `fail "msg"` | Avbryt renderingen med felet. Så rapporteras okända roller. |

## Anropsträdet

`_realm.tpl` är toppen, men inte den enda anroparen. De fem stora
funktionerna anropar mindre hjälpfunktioner, ofta i andra filer. Helm
laddar alla `_*.tpl` i en gemensam namnrymd, så filgränserna är bara för
läsbarhet. Prefixet `kafka-keycloak-realm.` är utelämnat nedan.

```
configmap.yaml  och  job.yaml
  └─ realm                          (_realm.tpl)
       ├─ validate                  (_helpers.tpl)
       ├─ groups                    (_realm_groups.tpl)
       │    ├─ teamNames
       │    └─ team
       ├─ identityProviders         (_realm_idp.tpl)
       ├─ identityProviderMappers   (_realm_idp.tpl)
       │    ├─ idpGroupsImporter
       │    ├─ teamNames, team      (_realm_groups.tpl)
       │    └─ idpGroupMapper
       │         └─ groupPath       (_realm_groups.tpl)
       ├─ groupsClientScope         (_realm_clients.tpl)
       └─ clients                   (_realm_clients.tpl)
            ├─ kafkaClient          (_realm_kafka.tpl)
            │    └─ kafkaAuthz
            │         ├─ teamNames, groupPath   (_realm_groups.tpl)
            │         ├─ teamGrants
            │         │    └─ team              (_realm_groups.tpl)
            │         ├─ roleProfile
            │         └─ resourceName
            └─ simpleClient
```

Ett sätt att tänka: `_realm.tpl` är `main()`, `_realm_groups.tpl` är ett
delat bibliotek eftersom allt i realmen är organiserat per team, och de
andra tre filerna är moduler som var och en äger en del av realm-filen.

`realm` anropas två gånger, från `configmap.yaml` för innehållet och från
`job.yaml` för checksumman. Det är därför Jobbets namn i fristående läge
ändras när realmen ändras.

## Dataflödet

```
values.yaml
   │
   ▼
_realm.tpl  ──►  _realm_groups.tpl   (teamNames, team, groups)
            ──►  _realm_idp.tpl      (identityProviders, identityProviderMappers)
            ──►  _realm_clients.tpl  (groupsClientScope, clients)
                      └──►  _realm_kafka.tpl  (kafkaClient -> kafkaAuthz)
   │
   ▼  toYaml
configmap.yaml   data.realm.yaml
   │
   ▼  sha256sum
job.yaml         checksum-annotation och, i fristående läge, Job-namnet
```

## Att felsöka en template

Rendera och titta på resultatet:

```
helm template kc charts/kafka-keycloak-realm \
  -f examples/values-teams.yaml -f examples/values-dev.yaml \
  | yq 'select(.kind=="ConfigMap") | .data["realm.yaml"]' | yq .
```

Testa en enskild del genom att tillfälligt lägga en template i en fil utan
`_` i namnet och rendera bara den med `helm template ... -s templates/debug.yaml`.

Felmeddelanden pekar på rad i template-filen. "nil pointer evaluating" betyder
nästan alltid att `.` inte är det man tror, oftast för att man är inne i en
`range` eller har anropat en dict-argument-template med `.` i stället för en
dict.

Testerna i `test/realm/` är det snabbaste sättet att se om en ändring gjorde
det man tänkte: `make realm-tests` tar några sekunder.
