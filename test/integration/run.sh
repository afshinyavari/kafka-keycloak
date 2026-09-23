#!/usr/bin/env bash
# Integration test: applies the rendered realm to a real Keycloak with
# keycloak-config-cli, using the environment from the rendered Job.
#
# Requires: docker (or podman with docker CLI compat), helm, yq, python3.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CHART="$ROOT/charts/kafka-keycloak-realm"
KC_IMAGE="${KC_IMAGE:-quay.io/keycloak/keycloak:26.5.5}"
KCC_IMAGE="${KCC_IMAGE:-docker.io/adorsys/keycloak-config-cli:6.5.1-26.5.5}"
NET="kcc-it-$$"
KC="kcc-it-keycloak-$$"
REALM=kafka-it
ADMIN_CLIENT=kafka-realm-admin
ADMIN_SECRET=admin-client-secret
# Not the keycloak-config-cli default (admin/admin), so a silent fallback to
# password grant against master cannot mask a broken client-credentials login.
BOOTSTRAP_PW="bootstrap-$$"
WORK="$(mktemp -d)"
FAILED=0

log()  { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }
pass() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; FAILED=1; }

cleanup() {
  docker rm -f "$KC" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

kcadm() { docker exec "$KC" /opt/keycloak/bin/kcadm.sh "$@"; }

render() { # render <out-dir> [extra helm args...]
  local out="$1"; shift
  mkdir -p "$out"
  helm template kc "$CHART" -f "$HERE/values.yaml" "$@" > "$out/all.yaml"
  yq 'select(.kind == "ConfigMap") | .data["realm.yaml"]' "$out/all.yaml" > "$out/realm.yaml"
  # Turn the Job's env into docker -e flags. Secret refs map onto the admin client.
  yq -r 'select(.kind == "Job") | .spec.template.spec.containers[0].env[]
         | select(.value != null) | .name + "=" + .value' "$out/all.yaml" > "$out/env"
  printf 'KEYCLOAK_CLIENTID=%s\nKEYCLOAK_CLIENTSECRET=%s\n' "$ADMIN_CLIENT" "$ADMIN_SECRET" >> "$out/env"
  # Debug logging so the checksum skip message is visible.
  sed -i 's/^LOGGING_LEVEL_KCC=.*/LOGGING_LEVEL_KCC=debug/' "$out/env"
  # Values for $(env:...) substitution.
  printf 'KAFKA_CLIENT_SECRET=kafka-secret\nKAFKA_UI_CLIENT_SECRET=ui-secret\nADFS_CLIENT_SECRET=adfs-secret\n' >> "$out/env"
}

import() { # import <dir> -> writes <dir>/log, returns kcc exit code
  local dir="$1"
  docker run --rm --network "$NET" --env-file "$dir/env" \
    -v "$dir/realm.yaml:/config/realm.yaml:ro" "$KCC_IMAGE" > "$dir/log" 2>&1 || { cat "$dir/log"; return 1; }
}

log "Starting Keycloak ($KC_IMAGE)"
docker network create "$NET" >/dev/null
docker run -d --name "$KC" --network "$NET" --network-alias keycloak \
  -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD="$BOOTSTRAP_PW" \
  -e KC_HEALTH_ENABLED=true "$KC_IMAGE" start-dev >/dev/null
for i in $(seq 1 90); do
  if docker exec "$KC" /opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 \
       --realm master --user admin --password "$BOOTSTRAP_PW" >/dev/null 2>&1; then break; fi
  sleep 2
  [ "$i" -eq 90 ] && { echo "Keycloak did not start"; docker logs "$KC" | tail -20; exit 1; }
done

log "Simulating onboarding by the Keycloak team: realm + admin client"
kcadm create realms -s realm="$REALM" -s enabled=true >/dev/null
ADMIN_CID=$(kcadm create clients -r "$REALM" -i -s clientId="$ADMIN_CLIENT" -s publicClient=false \
  -s serviceAccountsEnabled=true -s standardFlowEnabled=false -s secret="$ADMIN_SECRET" \
  -s 'description=Given to us by the Keycloak team')
kcadm add-roles -r "$REALM" --uusername "service-account-$ADMIN_CLIENT" --cclientid realm-management --rolename realm-admin
# Things that existed before we took over: a manual group and a manual client scope.
kcadm create groups -r "$REALM" -s name=manual-group >/dev/null
kcadm create client-scopes -r "$REALM" -s name=manual-scope -s protocol=openid-connect >/dev/null

log "First import"
render "$WORK/run1"
import "$WORK/run1" || { fail "first import failed"; exit 1; }
grep -q "Updating realm '$REALM'" "$WORK/run1/log" && pass "realm updated" || { fail "no 'Updating realm' log line"; grep -v "^\s*$" "$WORK/run1/log" | tail -20; }
grep -q "KEYCLOAK_LOGINREALM=$REALM" "$WORK/run1/env" && pass "job env logs in to our realm with client credentials" || fail "job env missing KEYCLOAK_LOGINREALM"
grep -Ei "error|exception" "$WORK/run1/log" && fail "errors in first import log" || pass "no errors in log"

log "Verifying state after first import"
kcadm get realms/"$REALM" > "$WORK/realm.json"
kcadm get groups -r "$REALM" --fields 'id,name' > "$WORK/groups.json"
PARENT_GID=$(kcadm get groups -r "$REALM" -q search=kafka -q exact=true --fields id --format csv --noquotes | head -1)
kcadm get "groups/$PARENT_GID/children" -r "$REALM" --fields name > "$WORK/subgroups.json"
kcadm get identity-provider/instances/adfs/mappers -r "$REALM" > "$WORK/mappers.json"
kcadm get clients -r "$REALM" --fields 'clientId,description,authorizationServicesEnabled' > "$WORK/clients.json"
kcadm get client-scopes -r "$REALM" --fields name > "$WORK/scopes.json"
KAFKA_CID=$(kcadm get clients -r "$REALM" -q clientId=kafka --fields id --format csv --noquotes)
kcadm get "clients/$KAFKA_CID/authz/resource-server/resource" -r "$REALM" --fields name,type > "$WORK/resources.json"
kcadm get "clients/$KAFKA_CID/authz/resource-server/permission" -r "$REALM" --fields name,type > "$WORK/permissions.json"
kcadm get "clients/$KAFKA_CID/authz/resource-server/policy" -r "$REALM" --fields name,type > "$WORK/policies.json"
kcadm get "clients/$KAFKA_CID/authz/resource-server/permission/scope" -r "$REALM" > "$WORK/perm-scope.json"

python3 - "$WORK" <<'PY'
import json, sys
w = sys.argv[1]
def load(n): return json.load(open(f"{w}/{n}"))
ok = True
def check(cond, msg):
    global ok
    print(("PASS " if cond else "FAIL ") + msg); ok = ok and cond

groups = load("groups.json")
parent = next((g for g in groups if g["name"] == "kafka"), None)
check(parent is not None, "parent group /kafka exists")
subs = sorted(g["name"] for g in load("subgroups.json"))
check(subs == ["billing", "cluster-admins", "orders"], f"team subgroups {subs}")
check(not any(g["name"] == "manual-group" for g in groups), "pre-existing manual group removed (groups fully managed)")

mappers = {m["name"]: m["identityProviderMapper"] for m in load("mappers.json")}
check(mappers.get("import-groups") == "oidc-user-attribute-idp-mapper", "groups attribute importer")
check(mappers.get("team:orders <- AD-Kafka-Orders") == "oidc-advanced-group-idp-mapper", "advanced group mapper for orders")
check("team:billing <- AD-Kafka-Billing-Ext" in mappers, "second AD group mapper for billing")
check("team:cluster-admins <- AD-Kafka-Platform" in mappers, "cluster-admins mapper")
check(mappers.get("username") == "oidc-username-idp-mapper", "extra mapper username kept")
check(mappers.get("email") == "oidc-user-attribute-idp-mapper", "extra mapper email kept")

clients = {c["clientId"]: c for c in load("clients.json")}
check("kafka-realm-admin" in clients, "external admin client still exists")
check(clients.get("kafka-realm-admin", {}).get("description") == "Given to us by the Keycloak team", "external admin client untouched")
check(clients.get("kafka", {}).get("authorizationServicesEnabled") is True, "kafka client has authorization services")
check("kafka-ui" in clients and "kafka-cli" in clients, "simple clients created")

scopes = {s["name"] for s in load("scopes.json")}
check("kafka-groups" in scopes, "kafka-groups client scope created")
check("manual-scope" in scopes, "manual client scope kept (no-delete)")
check("offline_access" in scopes and "profile" in scopes, "built-in client scopes kept")

resources = {r["name"]: r["type"] for r in load("resources.json")}
for n, t in {"Topic:orders.*": "Topic", "Group:orders.*": "Group", "TransactionalId:orders.*": "TransactionalId",
             "Topic:reference.*": "Topic", "Topic:billing.*": "Topic", "Cluster:*": "Cluster", "Topic:*": "Topic"}.items():
    check(resources.get(n) == t, f"resource {n} ({t})")
check(sum(1 for n in resources if n == "Topic:reference.*") == 1, "shared topic is a single resource")

perms = {p["name"] for p in load("permissions.json")}
for n in ["orders / topic-owner / Topic:orders.*", "orders / topic-reader / Topic:reference.*",
          "billing / topic-owner / Topic:reference.*", "cluster-admins / all / Cluster:*"]:
    check(n in perms, f"permission {n}")
policies = {p["name"]: p["type"] for p in load("policies.json")}
check(policies.get("team:orders") == "group", "group policy team:orders")
check(policies.get("team:cluster-admins") == "group", "group policy team:cluster-admins")

realm = load("realm.json")
check(realm.get("enabled") is True, "realm enabled")
sys.exit(0 if ok else 1)
PY
[ $? -eq 0 ] || FAILED=1

log "Second import must be a no-op"
render "$WORK/run2"
import "$WORK/run2" || fail "second import failed"
if grep -q "import checksum same" "$WORK/run2/log" && ! grep -q "Updating realm" "$WORK/run2/log"; then
  pass "unchanged realm skipped via checksum"
else
  fail "second import did not detect unchanged file"; tail -5 "$WORK/run2/log"
fi

log "Removing team billing and switching ownership to topic-reader"
render "$WORK/run3" --set teams.billing=null --set ownership.role=topic-reader
import "$WORK/run3" || { fail "third import failed"; }
kcadm get "groups/$PARENT_GID/children" -r "$REALM" --fields name > "$WORK/subgroups3.json"
kcadm get identity-provider/instances/adfs/mappers -r "$REALM" --fields name > "$WORK/mappers3.json"
kcadm get "clients/$KAFKA_CID/authz/resource-server/resource" -r "$REALM" --fields name > "$WORK/resources3.json"
kcadm get "clients/$KAFKA_CID/authz/resource-server/permission" -r "$REALM" --fields name > "$WORK/permissions3.json"
kcadm get "clients/$KAFKA_CID/authz/resource-server/policy" -r "$REALM" --fields name > "$WORK/policies3.json"
kcadm get clients -r "$REALM" --fields clientId > "$WORK/clients3.json"

python3 - "$WORK" <<'PY'
import json, sys
w = sys.argv[1]
def load(n): return json.load(open(f"{w}/{n}"))
ok = True
def check(cond, msg):
    global ok
    print(("PASS " if cond else "FAIL ") + msg); ok = ok and cond
subs = sorted(g["name"] for g in load("subgroups3.json"))
check(subs == ["cluster-admins", "orders"], f"billing group removed, subgroups now {subs}")
mappers = {m["name"] for m in load("mappers3.json")}
check(not any(n.startswith("team:billing") for n in mappers), "billing mappers removed")
check("team:orders <- AD-Kafka-Orders" in mappers, "orders mapper kept")
resources = {r["name"] for r in load("resources3.json")}
check("Topic:billing.*" not in resources, "billing resource removed")
check("Topic:reference.*" in resources, "shared resource kept while orders still reads it")
check("TransactionalId:orders.*" not in resources, "unreferenced TransactionalId resource removed in read-only mode")
perms = {p["name"] for p in load("permissions3.json")}
check("billing / topic-owner / Topic:billing.*" not in perms, "billing permission removed")
check("orders / topic-owner / Topic:orders.*" not in perms, "old owner permission removed")
check("orders / topic-reader / Topic:orders.*" in perms, "new reader permission created")
policies = {p["name"] for p in load("policies3.json")}
check("team:billing" not in policies, "billing policy removed")
clients = {c["clientId"] for c in load("clients3.json")}
check("kafka-realm-admin" in clients, "external admin client still exists after removal run")
sys.exit(0 if ok else 1)
PY
[ $? -eq 0 ] || FAILED=1

if [ "$FAILED" -eq 0 ]; then log "ALL INTEGRATION CHECKS PASSED"; else log "INTEGRATION CHECKS FAILED"; exit 1; fi
