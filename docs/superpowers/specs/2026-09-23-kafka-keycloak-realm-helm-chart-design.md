# Design: Helm-chart `kafka-keycloak-realm`

Datum: 2026-09-23
Status: utkast för granskning

## 1. Bakgrund och syfte

Ett Kafka-kluster (Red Hat Streams for Apache Kafka, Strimzi) på OpenShift ska
säkras med Red Hat build of Keycloak (RHBK). Tjänster autentiserar med mTLS och
får sina ACL:er via Strimzis `KafkaUser`-CRer. Människor loggar in via SSO
(ADFS) och ska få rollbaserad åtkomst till sina team-topics, både via
Kafka-klienter och via GUI:n som Kafka-UI och Schema Registry.

Auktoriseringen för människor sker med Keycloak Authorization Services på
klienten `kafka`, enligt Strimzis modell (`authorization.type: keycloak`).
Kafka-teamet äger en egen realm i en central Keycloak som Keycloak-teamet
driftar. Vid onboarding får Kafka-teamet realmen och en admin-klient med
rättigheter att administrera den. Den valfria Keycloak-operatorn används inte,
eftersom den saknar stöd för authorization services.

Målet är att all konfiguration av realmen, med undantag för det
Keycloak-teamet skapat, ska ligga i git och appliceras av ArgoCD. Verktyget
för själva importen är [keycloak-config-cli](https://github.com/adorsys/keycloak-config-cli),
som är idempotent och stödjer hela realm-representationen inklusive
`authorizationSettings`.

Charten låter ett team beskriva Kafka-behörigheter i termer av team, topics
och consumer groups i en values-fil, och genererar därifrån realm-filen och
ett Kubernetes Job som applicerar den.

### Framgångskriterier

- Ett nytt team med rättigheter till sina topics är en commit i en values-fil.
  Ingen manuell handpåläggning i Keycloaks admin-UI.
- En borttagen rad i git tar bort motsvarande permission, grupp och
  IdP-mapper i Keycloak vid nästa sync.
- Admin-klienten från Keycloak-teamet rörs aldrig.
- Inga hemligheter i git eller i den renderade realm-filen.
- Samma chart används för alla miljöer, med en values-fil per miljö.
- Oförändrad konfiguration ger en no-op-körning av Jobbet.

## 2. Scope och ägande

Charten heter `kafka-keycloak-realm`. En Helm-release motsvarar en realm.

Charten äger och hanterar med `full` (skapar, uppdaterar, raderar):

- realmens grundinställningar som anges i values
- identity providern mot ADFS och alla dess mappers
- grupperna under föräldragruppen (standard `/kafka`)
- klienten `kafka` med authorization settings (scopes, resurser, policies,
  permissions)
- enkla OIDC-klienter för GUI:n (till exempel `kafka-ui`, `schema-registry`)
- client scope `kafka-groups`
- alla övriga klienter i realmen, förutom de som listas i `externalClients`

Externa klienter, i praktiken admin-klienten från Keycloak-teamet, listas i
`externalClients` och renderas som en stub med enbart `clientId`.
keycloak-config-cli uppdaterar klienter med patch-semantik där null-fält
lämnas orörda, så stubben bevarar klienten oförändrad samtidigt som
`import.managed.client=full` kan användas för resten.

Utanför scope, men dokumenterat i README:

- Strimzi-konfigurationen (Kafka-CR med OAuth-listener och Keycloak-authorizer)
- skapandet av Kubernetes Secrets med klient-secrets (förväntas komma från
  External Secrets, Sealed Secrets eller motsvarande)
- realmen och admin-klienten som Keycloak-teamet skapar vid onboarding

## 3. Values-modellen

Modellen har två centrala begrepp: **rollprofiler**, som är återanvändbara
uppsättningar Kafka-scopes per resurstyp, och **team**, som knyter AD-grupper
till rollprofiler på konkreta resursmönster.

```yaml
keycloak:
  url: https://sso.example.com          # obligatorisk
  loginRealm: ""                        # standard: realm.name
  existingSecret: keycloak-config-cli   # obligatorisk; nycklar clientId, clientSecret
  secretKeys:
    clientId: clientId
    clientSecret: clientSecret
  sslVerify: true
  caBundleConfigMap: ""                 # valfri; nyckel ca-bundle.crt

realm:
  name: kafka-prod                      # obligatorisk
  displayName: Kafka (prod)
  settings: {}                          # råa realm-inställningar, t.ex. ssoSessionIdleTimeout

externalClients:
  - kafka-realm-admin                   # klienter som ägs av andra; renderas som stub

identityProvider:
  enabled: true
  alias: adfs
  providerId: oidc                      # oidc | saml; ADFS körs som OIDC hos oss
  displayName: ADFS
  groupsAttribute: groups               # OIDC-claim (eller SAML-attribut) med AD-grupper
  groupsAttributeFriendlyName: ""       # bara SAML: friendly name om mappern använder det
  userAttribute: groups                 # user-attribut i Keycloak att spara dem i
  syncMode: FORCE
  config:                               # rå IdP-config; hemligheter som $(env:...)
    authorizationUrl: https://adfs.example.com/adfs/oauth2/authorize
    tokenUrl: https://adfs.example.com/adfs/oauth2/token
    clientId: kafka-keycloak
    clientSecret: $(env:ADFS_CLIENT_SECRET)
  extraMappers:                         # befintliga mappers kopieras hit, t.ex. email, firstName, lastName, username
    - name: email
      identityProviderMapper: oidc-user-attribute-idp-mapper
      config:
        syncMode: FORCE
        claim: email
        user.attribute: email
    - name: username
      identityProviderMapper: oidc-username-idp-mapper
      config:
        syncMode: FORCE
        template: "${CLAIM.upn}"

kafka:
  clientId: kafka
  clusterName: ""                       # valfri; ger resursnamn "kafka-cluster:<namn>,Topic:..."
  secretEnv: KAFKA_CLIENT_SECRET        # miljövariabel i Jobbet som håller klientens secret
  scopes: [Create, Read, Write, Delete, Alter, Describe, ClusterAction,
           DescribeConfigs, AlterConfigs, IdempotentWrite]
  decisionStrategy: AFFIRMATIVE

groups:
  parent: kafka                         # team-grupper blir /kafka/<team>

roles:
  topic-owner:
    topic: [Describe, DescribeConfigs, Read, Write, Create, Delete, Alter, AlterConfigs]
    group: [Describe, Read, Delete]
    transactionalId: [Describe, Write]
  topic-reader:
    topic: [Describe, DescribeConfigs, Read]
    group: [Describe, Read]

ownership:
  role: topic-owner                     # vad "äga" innebär i denna miljö; prod sätter topic-reader

teams:                                  # map, så att values-filer kan slås ihop
  orders:
    description: Team Orders
    adGroups: ["AD-Kafka-Orders"]
    owns:
      topics: ["orders.*"]
      consumerGroups: ["orders.*"]
      transactionalIds: ["orders.*"]
    grants:                             # undantag utöver ägandet
      - role: topic-reader
        topics: ["reference.*"]

clusterAdmins:
  adGroups: ["AD-Kafka-Platform"]

clients:
  - name: kafka-ui
    redirectUris: ["https://kafka-ui.apps.example.com/*"]
    secretEnv: KAFKA_UI_CLIENT_SECRET    # utelämnas för public client
    serviceAccount: false
    attributes: {}                       # råa client attributes
    extra: {}                            # rå client-config som slås ihop sist
  - name: schema-registry
    redirectUris: ["https://schema-registry.apps.example.com/*"]
    secretEnv: SCHEMA_REGISTRY_CLIENT_SECRET

groupsClaim:
  name: groups
  fullPath: false                        # "orders" i stället för "/kafka/orders"
  includeAdAttribute: false              # lägg även med råa AD-gruppnamn
  adAttributeClaim: ad-groups

extraRealm: {}                           # rå realm-config, slås ihop sist med mergeOverwrite

image:
  repository: docker.io/adorsys/keycloak-config-cli
  tag: ""                                # pinnas till RHBK-versionen, t.ex. 6.4.0-26.2
  pullPolicy: IfNotPresent
imagePullSecrets: []

job:
  argocdHook: true
  hookDeletePolicy: BeforeHookCreation
  backoffLimit: 1
  activeDeadlineSeconds: 600
  ttlSecondsAfterFinished: 86400         # används bara när argocdHook är false
  envFrom: []                            # Secrets med värden för $(env:...)-substitution
  env: []                                # extra miljövariabler, t.ex. IMPORT_MANAGED_*-överstyrningar
  logLevel: info
  resources: {}
  podSecurityContext: {}
  securityContext: {}
  nodeSelector: {}
  tolerations: []
  affinity: {}
```

Regler för modellen:

- Resursmönster skickas vidare oförändrade till Keycloak och följer Strimzis
  semantik: ett avslutande `*` betyder prefix, `*` ensamt matchar allt, annars
  exakt namn. `orders.*` blir alltså `Topic:orders.*`.
- `teams` är en map där nyckeln är teamets namn. Maps slås ihop mellan
  values-filer, så en gemensam `values-teams.yaml` kan hålla alla team medan
  miljöfilen bara anger det som skiljer. Nyckeln måste vara ett giltigt
  gruppnamn.
- `owns` beskriver vad teamet äger. Vilken rollprofil ägande ger avgörs av
  `ownership.role`, som sätts per miljö: `topic-owner` i dev, `topic-reader`
  i prod där bara mTLS-tjänsterna skriver. Rollprofilerna själva betyder
  alltid samma sak. Internt behandlas `owns` som en grant med
  `role: <ownership.role>` och läggs först i teamets grants.
- `grants` är undantag utöver ägandet, till exempel läsrätt på ett annat
  teams topics, eller ett enskilt team som ska få skriva i prod.
- `grants[].role` och `ownership.role` måste referera en nyckel i `roles`.
  Charten validerar detta med `values.schema.json` och `fail` i mallarna.
- Rollprofiler får ha nycklarna `topic`, `group`, `transactionalId` och
  `cluster`. En grant använder bara de nycklar som den listar resurser för.
- `extraRealm` slås ihop sist med `mergeOverwrite`. Listor ersätts, de slås
  inte ihop. Detta är en ventil, inte ett sätt att kringgå modellen.

## 4. Den genererade realm-filen

Realm-filen byggs som en dict i named templates i `_realm.tpl` och
serialiseras med `toYaml` till `realm.yaml`. Alla namn är deterministiska så
att uppdateringar och raderingar i keycloak-config-cli fungerar.

### 4.1 Realm

```yaml
realm: <realm.name>
enabled: true
displayName: <realm.displayName>
# + realm.settings
```

### 4.2 Grupper

En föräldragrupp `/<groups.parent>` med en subgrupp per team, plus
`/<groups.parent>/cluster-admins` om `clusterAdmins.adGroups` inte är tom.
Attributet `description` sätts från teamets beskrivning.

### 4.3 Identity provider och mappers

`identityProviders` innehåller en post med `alias`, `providerId`,
`displayName`, `enabled: true`, `config.syncMode` och `identityProvider.config`
råa nycklar. Hemligheter i `config` anges av användaren som `$(env:NAMN)`.

`identityProviderMappers` hanteras med `full`, så allt som ska finnas på
providern måste renderas av charten. Listan innehåller:

1. **Attribute importer** som sparar alla AD-grupper som user-attribut, så att
   de fortsatt syns under Attributes på användaren. Den motsvarar den mapper
   som redan finns på ADFS-providern idag; värdena i `groupsAttribute`
   respektive `groupsAttributeFriendlyName` kopieras från den.
   SAML: `saml-user-attribute-idp-mapper` med `attribute.name` eller
   `attribute.friendly.name` och `user.attribute`. OIDC:
   `oidc-user-attribute-idp-mapper` med `claim` och `user.attribute`.
   Namn: `import-<userAttribute>`.
2. **Advanced Attribute to Group**, en per team och AD-grupp, eftersom
   villkoren i en mapper är AND och vi vill ha OR mellan AD-grupper.
   SAML: `saml-advanced-group-idp-mapper` med `attributes` som JSON-sträng
   `[{"key":"<groupsAttribute eller friendly name>","value":"<AD-grupp>"}]` och
   `are.attribute.values.regex: "false"`. OIDC: `oidc-advanced-group-idp-mapper`
   med `claims` och `are.claim.values.regex`. `group: /<parent>/<team>`,
   `syncMode: FORCE` så att medlemskapet tas bort när AD-gruppen försvinner.
   Namn: `team:<team> <- <AD-grupp>`.

3. **Övriga mappers** från `identityProvider.extraMappers`, renderade som
   de är med `identityProviderAlias` ifyllt. Här kopieras de befintliga
   mapparna för email, firstName, lastName och username template in, så att
   de inte raderas när charten tar över providern.

Cluster admins får sina gruppmappers på samma sätt mot `/<parent>/cluster-admins`.

### 4.4 Client scope `kafka-groups`

Protokoll `openid-connect`. Protocol mappers:

- `oidc-group-membership-mapper` med `claim.name: <groupsClaim.name>`,
  `full.path: <groupsClaim.fullPath>`, och claimen i id-token, access-token
  och userinfo.
- om `groupsClaim.includeAdAttribute`: `oidc-usermodel-attribute-mapper` med
  `user.attribute: <identityProvider.userAttribute>`,
  `claim.name: <groupsClaim.adAttributeClaim>`, `multivalued: "true"`.

### 4.5 Klienten `kafka`

```yaml
clientId: <kafka.clientId>
enabled: true
protocol: openid-connect
publicClient: false
secret: $(env:<kafka.secretEnv>)
serviceAccountsEnabled: true
authorizationServicesEnabled: true
standardFlowEnabled: false
directAccessGrantsEnabled: false
authorizationSettings:
  allowRemoteResourceManagement: false
  policyEnforcementMode: ENFORCING
  decisionStrategy: <kafka.decisionStrategy>
  scopes: [...]        # kafka.scopes
  resources: [...]
  policies: [...]      # både policies och permissions
```

**Resurser.** Unionen av alla resursmönster som teamen refererar, avdubblad.
Namn `<Typ>:<mönster>`, eller `kafka-cluster:<clusterName>,<Typ>:<mönster>`
om `kafka.clusterName` är satt. `type` sätts till `Topic`, `Group`,
`TransactionalId` eller `Cluster`. Varje resurs får hela `kafka.scopes` som
scopes, så att scope-permissions alltid är giltiga oavsett rollprofil.
Cluster admins ger resurserna `Cluster:*`, `Topic:*`, `Group:*` och
`TransactionalId:*`.

**Policies.** En group-policy per team med namn `team:<team>`, `logic: POSITIVE`,
`config.groups` som JSON-sträng `[{"path":"/<parent>/<team>","extendChildren":false}]`.
Cluster admins får `team:cluster-admins`.

**Permissions.** En scope-permission per team, grant och resurs, där
`owns` räknas som teamets första grant med rollen `ownership.role`:

```yaml
name: "<team> / <roll> / <resursnamn>"
type: scope
logic: POSITIVE
decisionStrategy: UNANIMOUS
config:
  resources: '["<resursnamn>"]'
  scopes: '["Describe","Read"]'        # från rollprofilen för resurstypen
  applyPolicies: '["team:<team>"]'
```

Cluster admins får en scope-permission per resurs ovan med alla scopes.

### 4.6 Enkla klienter

Per post i `clients`:

```yaml
clientId: <name>
name: <name>
enabled: true
protocol: openid-connect
publicClient: <true om secretEnv saknas>
secret: $(env:<secretEnv>)              # bara om secretEnv är satt
standardFlowEnabled: true
directAccessGrantsEnabled: false
serviceAccountsEnabled: <serviceAccount>
redirectUris: [...]
webOrigins: ["+"]
defaultClientScopes: [profile, email, roles, web-origins, kafka-groups]
attributes: <attributes>
# + extra, ihopslaget sist
```

### 4.7 Externa klienter

Per post i `externalClients`: `{clientId: <namn>}`. Ingenting annat.

### 4.8 Hemligheter

Realm-filen innehåller aldrig hemligheter. Alla secrets refereras med
`$(env:NAMN)` och substitueras av keycloak-config-cli vid körning
(`IMPORT_VARSUBSTITUTION_ENABLED=true`). Värdena kommer från Secrets som
listas i `job.envFrom`. Samma Secret som håller kafka-klientens secret
refereras av Kafka-CR:n på Strimzi-sidan, så värdet finns på ett ställe.

## 5. Kubernetes-objekt

### 5.1 ConfigMap

`<release>-realm` med nyckeln `realm.yaml`. Innehållet är den genererade
realm-filen.

### 5.2 Job

`<release>-import`. Kör keycloak-config-cli med `realm.yaml` monterad från
ConfigMappen på `/config`.

Miljövariabler:

| Variabel | Värde |
|---|---|
| `KEYCLOAK_URL` | `keycloak.url` |
| `KEYCLOAK_LOGIN_REALM` | `keycloak.loginRealm` eller `realm.name` |
| `KEYCLOAK_GRANT_TYPE` | `client_credentials` |
| `KEYCLOAK_CLIENTID` | från `keycloak.existingSecret` |
| `KEYCLOAK_CLIENTSECRET` | från `keycloak.existingSecret` |
| `KEYCLOAK_SSL_VERIFY` | `keycloak.sslVerify` |
| `KEYCLOAK_AVAILABILITYCHECK_ENABLED` | `true` |
| `KEYCLOAK_AVAILABILITYCHECK_TIMEOUT` | `120s` |
| `IMPORT_FILES_LOCATIONS` | `/config/realm.yaml` |
| `IMPORT_VARSUBSTITUTION_ENABLED` | `true` |
| `IMPORT_VALIDATE` | `true` |
| `LOGGING_LEVEL_KEYCLOAKCONFIGCLI` | `job.logLevel` |

Alla `IMPORT_MANAGED_*` lämnas på standardvärdet `full`. Överstyrningar görs
via `job.env`. Därutöver `envFrom` med varje Secret i `job.envFrom`.

**ArgoCD-läge** (`job.argocdHook: true`, standard): annoteringarna
`argocd.argoproj.io/hook: PostSync` och
`argocd.argoproj.io/hook-delete-policy: <job.hookDeletePolicy>`. Jobbet körs
efter varje sync. Med `BeforeHookCreation` ligger den senaste körningen kvar
för felsökning tills nästa sync. keycloak-config-cli:s checksum-cache gör att
en oförändrad realm-fil inte leder till några API-anrop utöver inloggning.
Ett misslyckat Job gör att ArgoCD markerar syncen som misslyckad, vilket är
den önskade signalen.

**Fristående läge** (`job.argocdHook: false`): Jobbet får namnet
`<release>-import-<sha256(realm.yaml) trunkerad till 8 tecken>` så att varje
ändring ger ett nytt Job, eftersom Job-spec är oföränderlig. `ttlSecondsAfterFinished`
städar gamla körningar.

**TLS mot intern CA** (`keycloak.caBundleConfigMap` satt): en init-container
med samma image kopierar JRE:ns `cacerts` till en emptyDir-volym, delar upp
PEM-bundlen i enskilda certifikat och importerar var och en med `keytool`.
Huvudcontainern får `JAVA_TOOL_OPTIONS` som pekar på truststoren. Detta gör
att OpenShifts injicerade CA-bundle kan användas utan att stänga av
TLS-verifiering.

**Säkerhet.** `runAsNonRoot: true`, `allowPrivilegeEscalation: false`,
`capabilities.drop: [ALL]`, `seccompProfile.type: RuntimeDefault`,
`readOnlyRootFilesystem: true` med emptyDir för `/tmp`. Inget `runAsUser`
hårdkodas, så att OpenShifts restricted SCC får tilldela UID.

### 5.3 Helm-chartens struktur

```
charts/kafka-keycloak-realm/
  Chart.yaml
  values.yaml
  values.schema.json
  templates/
    _helpers.tpl
    _realm.tpl            # named templates som bygger realm-dicten
    _realm_kafka.tpl      # kafka-klientens authorizationSettings
    _realm_idp.tpl        # identity provider och mappers
    _realm_clients.tpl    # enkla klienter, client scope, externa stubbar
    configmap.yaml
    job.yaml
    NOTES.txt
  tests/                  # helm-unittest
examples/
  values-teams.yaml      # gemensam teamdefinition
  values-dev.yaml        # ownership.role: topic-owner
  values-prod.yaml       # ownership.role: topic-reader
test/
  realm/                  # yq-baserade tester av realm-innehållet
  integration/            # lokal Keycloak i podman
docs/superpowers/specs/
README.md
```

## 6. Strimzi-integration

Dokumenteras i README, ingår inte i charten. Ett färdigt utdrag ur Kafka-CR:n:

- OAuth-listener med `validIssuerUri`, `jwksEndpointUri`, `userNameClaim`
  och `clientId: kafka` med `clientSecret` från samma Secret som Jobbet
  använder för `$(env:KAFKA_CLIENT_SECRET)`.
- `authorization.type: keycloak` med `tokenEndpointUri`, `clientId: kafka`,
  `delegateToKafkaAcls: true` så att mTLS-tjänsternas `KafkaUser`-ACL:er
  fortsätter gälla, och `superUsers` för brokrarnas egna principals.
- Hur `userNameClaim` bör väljas så att principalen blir läsbar i loggar
  och ACL:er, till exempel `preferred_username`.

## 7. Felhantering

- **Ogiltiga values** stoppas vid rendering: `values.schema.json` för typer
  och obligatoriska fält, `fail` i mallarna för semantiska fel som en grant
  som refererar en okänd rollprofil eller dubbla teamnamn. Felet syns i
  ArgoCD som ett renderingsfel innan något appliceras.
- **Ogiltig realm-fil** stoppas av `IMPORT_VALIDATE=true` i keycloak-config-cli
  innan API-anrop görs.
- **Keycloak otillgänglig** ger timeout efter 120 sekunder och ett misslyckat
  Job. `backoffLimit: 1` ger ett omförsök.
- **Delvis applicerad import.** keycloak-config-cli är inte transaktionell.
  En körning som fallerar halvvägs lämnar realmen delvis uppdaterad, men
  nästa körning konvergerar mot filen. Detta accepteras och dokumenteras.
- **Saknad miljövariabel** för `$(env:...)` gör att keycloak-config-cli
  fallerar med tydligt fel, hellre än att skriva ett tomt secret.

## 8. Test

### 8.1 Enhetstester av mallarna (helm-unittest)

Testar Kubernetes-objektens form: att Jobbet har rätt annoteringar i båda
lägena, att namnet innehåller checksumman i fristående läge, att init-containern
bara renderas när `caBundleConfigMap` är satt, att `envFrom` och secret-nycklar
hamnar rätt, och att security context är korrekt.

### 8.2 Tester av realm-innehållet (yq)

Ett skript renderar charten med testvalues, plockar ut `realm.yaml` och gör
strukturella påståenden med `yq`. Exempel på fall:

- två team som refererar samma topic ger en resurs men två permissions
- ett team med två AD-grupper ger två mappers mot samma grupp
- `providerId: oidc` ger `oidc-advanced-group-idp-mapper` med `claims`, och
  `providerId: saml` ger `saml-advanced-group-idp-mapper` med `attributes`
- `extraMappers` renderas med rätt alias och behåller sin config oförändrad
- ett team utan `owns` och utan grants ger grupp, mapper och policy men inga
  permissions
- samma team-map med `ownership.role: topic-owner` respektive `topic-reader`
  ger samma resurser men olika scopes i permissions
- två values-filer (gemensam teams-fil plus miljöfil) slås ihop så att teamen
  från basfilen finns kvar
- `clusterAdmins` tom ger ingen `cluster-admins`-grupp eller wildcard-resurser
- `externalClients` ger stubbar med enbart `clientId`
- `kafka.clusterName` satt ger prefixade resursnamn
- `extraRealm` skriver över genererade nycklar
- en grant med okänd rollprofil ger renderingsfel
- inga strängar i realm-filen innehåller något som liknar ett secret-värde,
  bara `$(env:...)`-referenser

### 8.3 Integrationstest (lokal Keycloak)

`test/integration/` innehåller en compose-fil för Keycloak i podman och ett
skript som:

1. startar Keycloak, skapar en realm och en admin-klient med `kcadm`, vilket
   simulerar Keycloak-teamets onboarding
2. renderar charten och kör keycloak-config-cli som container mot realmen
3. kör importen en gång till och kontrollerar att inga ändringar loggas
4. verifierar via admin-REST att grupper, mappers och permissions finns
5. tar bort ett team ur values, kör igen, och verifierar att teamets grupp,
   mapper, policy och permissions är borta medan admin-klienten finns kvar

Detta test körs manuellt eller i CI där podman finns, inte vid varje
`helm template`.

## 9. Öppna punkter att verifiera under implementationen

- Exakt image-tag för keycloak-config-cli som matchar den RHBK-version som
  körs. Tagg-formatet är `<cli-version>-<keycloak-version>`.
- Att keycloak-config-cli:s `remote-state`-funktion, som är påslagen som
  standard och gör att verktyget bara raderar objekt det själv skapat, inte
  stör borttagning av objekt som skapats manuellt före första körningen.
  Om den stör dokumenteras `IMPORT_REMOTE_STATE_ENABLED=false` som
  rekommendation.

## 10. Beslut som fattats under designen

- Operatorn används inte. keycloak-config-cli är ensam skrivare i realmen.
- Team representeras som Keycloak-grupper, inte roller, för synlighet i
  admin-UI:t och återanvändning i andra klienter.
- ADFS ansluts som OIDC-provider, vilket är så den befintliga providern är
  konfigurerad. SAML stöds men är inte standard.
- AD-grupper mappas till Keycloak-grupper med "Advanced Attribute to Group",
  eftersom Authorization Services inte kan utvärdera user-attribut direkt
  utan JS-policies.
- `import.managed.client=full` med stubbar för externa klienter, i stället
  för `no-delete`, så att borttagna klienter i git faktiskt försvinner.
- Jobbet är en ArgoCD PostSync-hook som standard, med fristående läge som
  alternativ.
- Team är en map och ägande är ett eget begrepp (`owns` plus
  `ownership.role`), så att teamdefinitionen är identisk i alla miljöer och
  skillnaden mellan dev och prod är en rad i miljöfilen.
