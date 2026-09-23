import unittest

from helpers import render_realm, by_name


TEAMS = {"orders": {"description": "Team Orders", "adGroups": ["AD-Kafka-Orders"]},
         "billing": {"adGroups": ["AD-Kafka-Billing"]}}


class Groups(unittest.TestCase):
    def test_parent_group_with_one_subgroup_per_team(self):
        realm = render_realm({"teams": TEAMS})
        parent = by_name(realm["groups"], "kafka")
        self.assertEqual(sorted(g["name"] for g in parent["subGroups"]), ["billing", "orders"])
        self.assertEqual(by_name(parent["subGroups"], "orders")["attributes"]["description"], ["Team Orders"])

    def test_parent_group_name_is_configurable(self):
        realm = render_realm({"teams": TEAMS, "groups": {"parent": "streams"}})
        self.assertEqual([g["name"] for g in realm["groups"]], ["streams"])

    def test_cluster_admins_group_only_when_configured(self):
        realm = render_realm({"teams": TEAMS})
        self.assertNotIn("cluster-admins", [g["name"] for g in by_name(realm["groups"], "kafka")["subGroups"]])
        realm = render_realm({"teams": TEAMS, "clusterAdmins": {"adGroups": ["AD-Kafka-Platform"]}})
        self.assertIn("cluster-admins", [g["name"] for g in by_name(realm["groups"], "kafka")["subGroups"]])

    def test_team_set_to_null_is_dropped(self):
        # Lets an environment file remove a team from the shared teams file.
        realm = render_realm({"teams": {**TEAMS, "billing": None}})
        self.assertEqual([g["name"] for g in by_name(realm["groups"], "kafka")["subGroups"]], ["orders"])
        kafka = [c for c in realm["clients"] if c["clientId"] == "kafka"][0]
        self.assertNotIn("team:billing", [p["name"] for p in kafka["authorizationSettings"]["policies"]])


if __name__ == "__main__":
    unittest.main()
