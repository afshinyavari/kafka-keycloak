import unittest

from helpers import render_realm, by_name

CLIENTS = [
    {"name": "kafka-ui", "redirectUris": ["https://kafka-ui.apps.example.com/*"], "secretEnv": "KAFKA_UI_SECRET"},
    {"name": "schema-registry", "redirectUris": ["https://sr.apps.example.com/*"],
     "secretEnv": "SR_SECRET", "serviceAccount": True, "attributes": {"post.logout.redirect.uris": "+"},
     "extra": {"implicitFlowEnabled": True, "webOrigins": ["https://sr.apps.example.com"]}},
    {"name": "kafka-cli", "redirectUris": ["http://localhost:*"]},
]


def client(realm, client_id):
    return by_name([{**c, "name": c["clientId"]} for c in realm["clients"]], client_id)


class SimpleClients(unittest.TestCase):
    def test_confidential_client_shape(self):
        c = client(render_realm({"clients": CLIENTS}), "kafka-ui")
        self.assertEqual(c["secret"], "$(env:KAFKA_UI_SECRET)")
        self.assertFalse(c["publicClient"])
        self.assertTrue(c["standardFlowEnabled"])
        self.assertFalse(c["directAccessGrantsEnabled"])
        self.assertFalse(c["serviceAccountsEnabled"])
        self.assertEqual(c["redirectUris"], ["https://kafka-ui.apps.example.com/*"])
        self.assertEqual(c["webOrigins"], ["+"])
        self.assertEqual(c["protocol"], "openid-connect")
        self.assertTrue(c["enabled"])
        self.assertEqual(c["defaultClientScopes"], ["profile", "email", "roles", "web-origins", "basic", "acr", "kafka-groups"])

    def test_default_client_scopes_configurable_but_always_include_groups(self):
        realm = render_realm({"clients": CLIENTS, "clientDefaults": {"scopes": ["profile", "email"]}})
        self.assertEqual(client(realm, "kafka-ui")["defaultClientScopes"], ["profile", "email", "kafka-groups"])

    def test_public_client_without_secret_env(self):
        c = client(render_realm({"clients": CLIENTS}), "kafka-cli")
        self.assertTrue(c["publicClient"])
        self.assertNotIn("secret", c)

    def test_service_account_attributes_and_extra_override(self):
        c = client(render_realm({"clients": CLIENTS}), "schema-registry")
        self.assertTrue(c["serviceAccountsEnabled"])
        self.assertEqual(c["attributes"], {"post.logout.redirect.uris": "+"})
        self.assertTrue(c["implicitFlowEnabled"])
        self.assertEqual(c["webOrigins"], ["https://sr.apps.example.com"])

    def test_no_simple_clients_by_default(self):
        realm = render_realm()
        self.assertEqual([c["clientId"] for c in realm["clients"]], ["kafka"])


class GroupsClientScope(unittest.TestCase):
    def test_scope_with_group_membership_mapper(self):
        realm = render_realm({"clients": CLIENTS})
        scope = by_name(realm["clientScopes"], "kafka-groups")
        self.assertEqual(scope["protocol"], "openid-connect")
        m = by_name(scope["protocolMappers"], "groups")
        self.assertEqual(m["protocolMapper"], "oidc-group-membership-mapper")
        self.assertEqual(m["config"]["claim.name"], "groups")
        self.assertEqual(m["config"]["full.path"], "false")
        for k in ("id.token.claim", "access.token.claim", "userinfo.token.claim"):
            self.assertEqual(m["config"][k], "true")
        self.assertEqual(len(scope["protocolMappers"]), 1)

    def test_claim_name_and_full_path_configurable(self):
        realm = render_realm({"groupsClaim": {"name": "teams", "fullPath": True}})
        m = by_name(by_name(realm["clientScopes"], "kafka-groups")["protocolMappers"], "teams")
        self.assertEqual(m["config"]["claim.name"], "teams")
        self.assertEqual(m["config"]["full.path"], "true")

    def test_optional_ad_attribute_claim(self):
        realm = render_realm({"groupsClaim": {"includeAdAttribute": True, "adAttributeClaim": "ad-groups"},
                              "identityProvider": {"userAttribute": "adgroups"}})
        m = by_name(by_name(realm["clientScopes"], "kafka-groups")["protocolMappers"], "ad-groups")
        self.assertEqual(m["protocolMapper"], "oidc-usermodel-attribute-mapper")
        self.assertEqual(m["config"]["user.attribute"], "adgroups")
        self.assertEqual(m["config"]["claim.name"], "ad-groups")
        self.assertEqual(m["config"]["multivalued"], "true")


class ExternalClients(unittest.TestCase):
    def test_external_clients_are_bare_stubs(self):
        realm = render_realm({"externalClients": ["kafka-realm-admin", "other"]})
        self.assertEqual(client(realm, "kafka-realm-admin"), {"clientId": "kafka-realm-admin", "name": "kafka-realm-admin"})
        self.assertIn("other", [c["clientId"] for c in realm["clients"]])


class ExtraRealm(unittest.TestCase):
    def test_extra_realm_overrides_generated_keys_and_adds_new_ones(self):
        realm = render_realm({"extraRealm": {"enabled": False, "loginTheme": "corp",
                                             "roles": {"realm": [{"name": "custom"}]}}})
        self.assertFalse(realm["enabled"])
        self.assertEqual(realm["loginTheme"], "corp")
        self.assertEqual(realm["roles"]["realm"][0]["name"], "custom")
        # generated content survives
        self.assertEqual(realm["clients"][0]["clientId"], "kafka")


if __name__ == "__main__":
    unittest.main()
