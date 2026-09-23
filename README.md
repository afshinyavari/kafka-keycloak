# kafka-keycloak-realm

Helm-chart som hanterar vår Keycloak-realm för Kafka via git. Team, AD-grupper,
topics och consumer groups beskrivs i values-filer. Charten genererar en
realm-fil och ett Kubernetes Job som applicerar den med
[keycloak-config-cli](https://github.com/adorsys/keycloak-config-cli).

Designen finns i [docs/superpowers/specs](docs/superpowers/specs/).

## Vad charten äger

| Objekt i realmen | Hantering |
|---|---|
| ADFS identity provider och alla dess mappers | full |
| Grupper (`/kafka/<team>`) | full |
| Klienten `kafka` med authorization services | full |
| Enkla klienter (Kafka UI, Schema Registry, ...) | full |
| Client scope `kafka-groups` | skapas, men inga andra scopes raderas |
| Klienter i `externalClients` (admin-klienten från Keycloak-teamet) | rörs aldrig |

"Full" betyder att det som tas bort ur git tas bort i Keycloak vid nästa sync.
Objekt som skapats för hand i Keycloak inom dessa kategorier raderas också, så
allt ska in via git.

## Modellen

```yaml
roles:                       # återanvändbara scope-profiler
  topic-owner:
    topic: [Describe, DescribeConfigs, Read, Write, Create, Delete, Alter, AlterConfigs]
    group: [Describe, Read, Delete]
    transactionalId: [Describe, Write]
  topic-reader:
    topic: [Describe, DescribeConfigs, Read]
    group: [Describe, Read]

ownership:
  role: topic-owner          # dev: topic-owner, prod: topic-reader

teams:
  orders:
    adGroups: ["AD-Kafka-Orders"]
    owns:
      topics: ["orders.*"]
      consumerGroups: ["orders.*"]
    grants:                  # undantag utöver ägandet
      - role: topic-reader
        topics: ["reference.*"]

clusterAdmins:
  adGroups: ["AD-Kafka-Platform"]
```

Per team genereras:

- en grupp `/kafka/<team>`
- en IdP-mapper per AD-grupp ("Advanced Claim to Group", sync mode FORCE) som
  lägger användaren i gruppen vid inloggning och tar bort den när AD-gruppen försvinner
- en group-policy `team:<team>` på klienten `kafka`
- en scope-permission per resurs, `<team> / <roll> / Topic:orders.*`, med
  scopes från rollprofilen

Resursmönster följer Strimzis semantik: avslutande `*` är prefix, ensamt `*`
matchar allt, annars exakt namn.

`teams` är en map. Lägg alla team i en gemensam fil och låt miljöfilen sätta
`ownership.role`, realm och Keycloak-adress. Ett team kan tas bort i en miljö
med `teams.<namn>: null`.

## Filer per miljö

Se [examples/](examples/):

- `values-teams.yaml`: teamen, identisk i alla miljöer
- `values-dev.yaml`: `ownership.role: topic-owner`
- `values-prod.yaml`: `ownership.role: topic-reader`, bara mTLS-tjänster skriver

ArgoCD:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kafka-keycloak-realm-prod
spec:
  source:
    repoURL: https://git.example.com/kafka/kafka-keycloak.git
    path: charts/kafka-keycloak-realm
    helm:
      valueFiles:
        - ../../examples/values-teams.yaml
        - ../../examples/values-prod.yaml
  destination:
    namespace: kafka
  syncPolicy:
    automated: {}
```

Jobbet är en PostSync-hook och körs efter varje sync. En oförändrad realm-fil
blir en no-op via keycloak-config-cli:s checksumma. Misslyckas Jobbet blir
syncen röd i ArgoCD, och den senaste körningen ligger kvar för `oc logs`.

## Hemligheter

Inga hemligheter i git. Realm-filen refererar `$(env:NAMN)` och
keycloak-config-cli byter ut dem vid körning från Secrets i `job.envFrom`.

| Secret | Nycklar | Används av |
|---|---|---|
| `kafka-keycloak-admin` | `clientId`, `clientSecret` | Jobbets inloggning (admin-klienten från Keycloak-teamet) |
| `kafka-oauth-client` | `KAFKA_CLIENT_SECRET` | `kafka`-klientens secret. Samma Secret refereras av Kafka-CR:n |
| `kafka-gui-clients` | `KAFKA_UI_CLIENT_SECRET`, ... | GUI-klienternas secrets |
| `adfs-client` | `ADFS_CLIENT_SECRET` | ADFS-providerns client secret |

Värdet på `KAFKA_CLIENT_SECRET` väljer ni själva (slumpa det). keycloak-config-cli
sätter det på klienten i Keycloak, och Strimzi läser samma Secret. Skapa Secrets
med External Secrets, Sealed Secrets eller motsvarande.

## Onboarding av en ny realm

1. Keycloak-teamet skapar realmen och en admin-klient med rollen `realm-admin`.
2. Lägg admin-klientens `clientId` och `clientSecret` i Secreten `kafka-keycloak-admin`.
3. Lägg admin-klientens `clientId` i `externalClients` så att charten aldrig rör den.
4. Kopiera den befintliga ADFS-providerns config till `identityProvider.config`
   och dess mappers (email, firstName, lastName, username) till
   `identityProvider.extraMappers`. Se `examples/values-dev.yaml`.
5. Syncа. Första körningen tar över realmen.

## Strimzi

Kafka-CR:n använder OAuth för människor och Keycloak-authorizern med delegering
till Kafka-ACL:er, så att mTLS-tjänsternas `KafkaUser`-ACL:er fortsätter gälla.

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: my-cluster
spec:
  kafka:
    listeners:
      - name: tls                     # tjänster, mTLS
        port: 9093
        type: internal
        tls: true
        authentication:
          type: tls
      - name: oauth                   # människor via SSO, Kafka UI, CLI
        port: 9094
        type: route
        tls: true
        authentication:
          type: oauth
          validIssuerUri: https://sso.example.com/realms/kafka-prod
          jwksEndpointUri: https://sso.example.com/realms/kafka-prod/protocol/openid-connect/certs
          userNameClaim: preferred_username
          maxSecondsWithoutReauthentication: 3600
          clientId: kafka             # samma klient som charten skapar
          clientSecret:
            secretName: kafka-oauth-client
            key: KAFKA_CLIENT_SECRET
          tlsTrustedCertificates:
            - secretName: sso-ca
              certificate: ca.crt
    authorization:
      type: keycloak
      clientId: kafka
      tokenEndpointUri: https://sso.example.com/realms/kafka-prod/protocol/openid-connect/token
      delegateToKafkaAcls: true
      grantsRefreshPeriodSeconds: 60
      tlsTrustedCertificates:
        - secretName: sso-ca
          certificate: ca.crt
```

`userNameClaim: preferred_username` ger principalen `User:<användarnamn>`,
vilket är läsbart i loggar. Användarnamnet kommer från ADFS via mappern
`username` (`${CLAIM.upn}`).

## Intern CA

Sätt `keycloak.caBundleConfigMap` till en ConfigMap med PEM-bundle, till
exempel en med etiketten `config.openshift.io/inject-trusted-cabundle: "true"`.
En init-container bygger en Java-truststore av den. Stäng inte av
`keycloak.sslVerify`.

## Test

```
make test          # lint, helm-unittest, realm-tester (ingen Docker)
make integration   # riktig Keycloak i Docker, ca 2 minuter
```

Kräver `helm` med pluginen `unittest`, `python3` med PyYAML, `yq` och för
integrationstestet `docker`.

Integrationstestet simulerar Keycloak-teamets onboarding, applicerar realmen
med exakt de miljövariabler Jobbet renderar, kör en gång till och kontrollerar
att det är en no-op, tar bort ett team och byter `ownership.role`, och
verifierar att grupp, mappers, policy, permissions och resurser försvinner
medan admin-klienten finns kvar.

## Felsökning

- **Jobbet fallerar med `Unknown role`** i renderingen: en grant refererar en
  rollprofil som inte finns under `roles`.
- **`Cannot resolve variable`** från keycloak-config-cli: ett `$(env:NAMN)`
  saknas i Secrets under `job.envFrom`.
- **Användaren hamnar inte i gruppen**: kontrollera att AD-gruppnamnet i
  `adGroups` är exakt det värde som finns under Attributes på användaren, och
  att providerns sync mode är FORCE så att medlemskap omvärderas vid inloggning.
- **Mer loggning**: `job.logLevel: debug`.
