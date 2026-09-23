import json
import os
import unittest

from helpers import render_realm, render_manifests, find, by_name

EX = os.path.join(os.path.dirname(__file__), "..", "..", "examples")
TEAMS = os.path.join(EX, "values-teams.yaml")
DEV = os.path.join(EX, "values-dev.yaml")
PROD = os.path.join(EX, "values-prod.yaml")


def scopes_of(realm, perm_name):
    kafka = [c for c in realm["clients"] if c["clientId"] == "kafka"][0]
    p = by_name(kafka["authorizationSettings"]["policies"], perm_name)
    return sorted(json.loads(p["config"]["scopes"]))


class Examples(unittest.TestCase):
    def test_dev_merges_shared_teams_and_grants_ownership(self):
        realm = render_realm(values_files=[TEAMS, DEV], base={})
        self.assertEqual(realm["realm"], "kafka-dev")
        parent = by_name(realm["groups"], "kafka")
        self.assertIn("orders", [g["name"] for g in parent["subGroups"]])
        self.assertIn("Write", scopes_of(realm, "orders / topic-owner / Topic:orders.*"))

    def test_prod_same_teams_read_only_ownership(self):
        realm = render_realm(values_files=[TEAMS, PROD], base={})
        self.assertEqual(realm["realm"], "kafka-prod")
        self.assertEqual(scopes_of(realm, "orders / topic-reader / Topic:orders.*"), ["Describe", "DescribeConfigs", "Read"])

    def test_examples_carry_existing_idp_mappers_and_external_admin_client(self):
        realm = render_realm(values_files=[TEAMS, DEV], base={})
        names = [m["name"] for m in realm["identityProviderMappers"]]
        for n in ["email", "firstName", "lastName", "username", "import-groups"]:
            self.assertIn(n, names)
        self.assertIn("kafka-realm-admin", [c["clientId"] for c in realm["clients"]])

    def test_examples_render_job_with_secret_env_sources(self):
        job = find(render_manifests(values_files=[TEAMS, DEV], base={}), "Job")
        self.assertTrue(job["spec"]["template"]["spec"]["containers"][0]["envFrom"])


if __name__ == "__main__":
    unittest.main()
