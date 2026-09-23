import json
import unittest

from helpers import render_realm, render_error, by_name

ALL_SCOPES = ["Create", "Read", "Write", "Delete", "Alter", "Describe", "ClusterAction",
              "DescribeConfigs", "AlterConfigs", "IdempotentWrite"]

TEAMS = {
    "orders": {"adGroups": ["AD-Kafka-Orders"],
               "owns": {"topics": ["orders.*"], "consumerGroups": ["orders.*"], "transactionalIds": ["orders.*"]},
               "grants": [{"role": "topic-reader", "topics": ["reference.*"]}]},
    "billing": {"adGroups": ["AD-Kafka-Billing"],
                "owns": {"topics": ["billing.*", "reference.*"], "consumerGroups": ["billing.*"]}},
    "lurkers": {"adGroups": ["AD-Kafka-Lurkers"]},
}


def kafka_client(realm, client_id="kafka"):
    return by_name([{**c, "name": c["clientId"]} for c in realm["clients"]], client_id)


def authz(realm, **kw):
    return kafka_client(realm, **kw)["authorizationSettings"]


def policies(realm, type_):
    return [p for p in authz(realm)["policies"] if p["type"] == type_]


def perm(realm, name):
    p = by_name(policies(realm, "scope"), name)
    return {"resources": json.loads(p["config"]["resources"]),
            "scopes": sorted(json.loads(p["config"]["scopes"])),
            "applyPolicies": json.loads(p["config"]["applyPolicies"]),
            "raw": p}


class KafkaClient(unittest.TestCase):
    def test_client_shape(self):
        c = kafka_client(render_realm({"teams": TEAMS}))
        self.assertEqual(c["secret"], "$(env:KAFKA_CLIENT_SECRET)")
        self.assertFalse(c["publicClient"])
        self.assertTrue(c["serviceAccountsEnabled"])
        self.assertTrue(c["authorizationServicesEnabled"])
        self.assertFalse(c["standardFlowEnabled"])
        self.assertFalse(c["directAccessGrantsEnabled"])
        self.assertEqual(c["protocol"], "openid-connect")

    def test_authz_settings_and_scopes(self):
        a = authz(render_realm({"teams": TEAMS}))
        self.assertFalse(a["allowRemoteResourceManagement"])
        self.assertEqual(a["policyEnforcementMode"], "ENFORCING")
        self.assertEqual(a["decisionStrategy"], "AFFIRMATIVE")
        self.assertEqual([s["name"] for s in a["scopes"]], ALL_SCOPES)

    def test_client_id_and_secret_env_configurable(self):
        realm = render_realm({"teams": TEAMS, "kafka": {"clientId": "kafka-broker", "secretEnv": "BROKER_SECRET"}})
        self.assertEqual(kafka_client(realm, "kafka-broker")["secret"], "$(env:BROKER_SECRET)")


class Resources(unittest.TestCase):
    def test_union_of_patterns_deduplicated_with_all_scopes(self):
        res = authz(render_realm({"teams": TEAMS}))["resources"]
        names = sorted(r["name"] for r in res)
        self.assertEqual(names, ["Group:billing.*", "Group:orders.*", "Topic:billing.*", "Topic:orders.*",
                                 "Topic:reference.*", "TransactionalId:orders.*"])
        ref = by_name(res, "Topic:reference.*")
        self.assertEqual(ref["type"], "Topic")
        self.assertEqual(sorted(s["name"] for s in ref["scopes"]), sorted(ALL_SCOPES))
        self.assertEqual(by_name(res, "Group:orders.*")["type"], "Group")
        self.assertEqual(by_name(res, "TransactionalId:orders.*")["type"], "TransactionalId")

    def test_cluster_name_prefixes_resource_names(self):
        realm = render_realm({"teams": TEAMS, "kafka": {"clusterName": "my-cluster"}})
        res = authz(realm)["resources"]
        self.assertIn("kafka-cluster:my-cluster,Topic:orders.*", [r["name"] for r in res])
        self.assertEqual(perm(realm, "orders / topic-owner / kafka-cluster:my-cluster,Topic:orders.*")["resources"],
                         ["kafka-cluster:my-cluster,Topic:orders.*"])

    def test_cluster_admins_add_wildcard_resources(self):
        realm = render_realm({"teams": TEAMS, "clusterAdmins": {"adGroups": ["AD-Platform"]}})
        names = [r["name"] for r in authz(realm)["resources"]]
        for n in ["Cluster:*", "Topic:*", "Group:*", "TransactionalId:*"]:
            self.assertIn(n, names)
        self.assertEqual(by_name(authz(realm)["resources"], "Cluster:*")["type"], "Cluster")

    def test_no_wildcards_without_cluster_admins(self):
        names = [r["name"] for r in authz(render_realm({"teams": TEAMS}))["resources"]]
        self.assertNotIn("Cluster:*", names)
        self.assertNotIn("Topic:*", names)


class Policies(unittest.TestCase):
    def test_group_policy_per_team(self):
        pols = policies(render_realm({"teams": TEAMS}), "group")
        self.assertEqual(sorted(p["name"] for p in pols), ["team:billing", "team:lurkers", "team:orders"])
        p = by_name(pols, "team:orders")
        self.assertEqual(p["logic"], "POSITIVE")
        self.assertEqual(json.loads(p["config"]["groups"]), [{"path": "/kafka/orders", "extendChildren": False}])

    def test_cluster_admins_policy(self):
        pols = policies(render_realm({"teams": TEAMS, "clusterAdmins": {"adGroups": ["AD-Platform"]}}), "group")
        self.assertEqual(json.loads(by_name(pols, "team:cluster-admins")["config"]["groups"])[0]["path"],
                         "/kafka/cluster-admins")


class Permissions(unittest.TestCase):
    def test_owns_uses_ownership_role(self):
        realm = render_realm({"teams": TEAMS})  # ownership.role defaults to topic-owner
        p = perm(realm, "orders / topic-owner / Topic:orders.*")
        self.assertEqual(p["resources"], ["Topic:orders.*"])
        self.assertEqual(p["scopes"], sorted(["Describe", "DescribeConfigs", "Read", "Write", "Create",
                                              "Delete", "Alter", "AlterConfigs"]))
        self.assertEqual(p["applyPolicies"], ["team:orders"])
        self.assertEqual(p["raw"]["decisionStrategy"], "UNANIMOUS")
        self.assertEqual(p["raw"]["logic"], "POSITIVE")
        self.assertEqual(perm(realm, "orders / topic-owner / Group:orders.*")["scopes"],
                         sorted(["Describe", "Read", "Delete"]))
        self.assertEqual(perm(realm, "orders / topic-owner / TransactionalId:orders.*")["scopes"],
                         sorted(["Describe", "Write"]))

    def test_ownership_role_switch_changes_scopes_not_resources(self):
        dev = render_realm({"teams": TEAMS, "ownership": {"role": "topic-owner"}})
        prod = render_realm({"teams": TEAMS, "ownership": {"role": "topic-reader"}})
        # Resources are only created when some permission references them, so the
        # TransactionalId resource disappears in prod (topic-reader has no transactionalId scopes).
        without_tx = lambda realm: [r["name"] for r in authz(realm)["resources"] if r["type"] != "TransactionalId"]
        self.assertEqual(without_tx(dev), without_tx(prod))
        self.assertEqual(perm(prod, "orders / topic-reader / Topic:orders.*")["scopes"],
                         sorted(["Describe", "DescribeConfigs", "Read"]))
        self.assertNotIn("orders / topic-owner / Topic:orders.*", [p["name"] for p in policies(prod, "scope")])

    def test_grants_add_permissions_and_shared_topic_gives_one_resource_two_permissions(self):
        realm = render_realm({"teams": TEAMS})
        self.assertEqual(len([r for r in authz(realm)["resources"] if r["name"] == "Topic:reference.*"]), 1)
        self.assertEqual(perm(realm, "orders / topic-reader / Topic:reference.*")["applyPolicies"], ["team:orders"])
        self.assertEqual(perm(realm, "billing / topic-owner / Topic:reference.*")["applyPolicies"], ["team:billing"])

    def test_team_without_owns_or_grants_has_policy_but_no_permissions(self):
        realm = render_realm({"teams": TEAMS})
        self.assertEqual([p["name"] for p in policies(realm, "scope") if p["name"].startswith("lurkers")], [])
        self.assertIn("team:lurkers", [p["name"] for p in policies(realm, "group")])

    def test_grant_role_key_missing_for_resource_type_skips_that_type(self):
        # topic-reader has no transactionalId key, so a grant on transactionalIds yields no permission for it
        teams = {"t": {"adGroups": ["x"], "grants": [{"role": "topic-reader", "transactionalIds": ["tx.*"]}]}}
        realm = render_realm({"teams": teams})
        self.assertEqual(policies(realm, "scope"), [])
        self.assertNotIn("TransactionalId:tx.*", [r["name"] for r in authz(realm)["resources"]])

    def test_cluster_admins_get_all_scopes_on_wildcards(self):
        realm = render_realm({"teams": TEAMS, "clusterAdmins": {"adGroups": ["AD-Platform"]}})
        p = perm(realm, "cluster-admins / all / Cluster:*")
        self.assertEqual(p["scopes"], sorted(ALL_SCOPES))
        self.assertEqual(p["applyPolicies"], ["team:cluster-admins"])
        self.assertEqual(perm(realm, "cluster-admins / all / Topic:*")["scopes"], sorted(ALL_SCOPES))

    def test_custom_role_profile(self):
        roles = {"producer": {"topic": ["Describe", "Write"], "cluster": ["IdempotentWrite"]}}
        teams = {"t": {"adGroups": ["x"], "grants": [{"role": "producer", "topics": ["a"], "cluster": True}]}}
        realm = render_realm({"teams": teams, "roles": roles})
        self.assertEqual(perm(realm, "t / producer / Topic:a")["scopes"], ["Describe", "Write"])
        self.assertEqual(perm(realm, "t / producer / Cluster:*")["scopes"], ["IdempotentWrite"])


class Validation(unittest.TestCase):
    def test_unknown_grant_role_fails(self):
        err = render_error({"teams": {"t": {"adGroups": ["x"], "grants": [{"role": "nope", "topics": ["a"]}]}}})
        self.assertIn("nope", err)
        self.assertIn("roles", err)

    def test_unknown_ownership_role_fails(self):
        err = render_error({"teams": TEAMS, "ownership": {"role": "nope"}})
        self.assertIn("ownership.role", err)


if __name__ == "__main__":
    unittest.main()
