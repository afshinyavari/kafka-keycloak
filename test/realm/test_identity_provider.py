import json
import unittest

from helpers import render_realm, by_name

IDP = {"enabled": True, "alias": "adfs", "providerId": "oidc", "displayName": "ADFS",
       "config": {"authorizationUrl": "https://adfs.example.com/adfs/oauth2/authorize",
                  "clientSecret": "$(env:ADFS_CLIENT_SECRET)"}}
TEAMS = {"orders": {"adGroups": ["AD-Kafka-Orders", "AD-Kafka-Orders-Ext"]},
         "billing": {"adGroups": ["AD-Kafka-Billing"]}}


def mappers(realm, alias="adfs"):
    return [m for m in realm["identityProviderMappers"] if m["identityProviderAlias"] == alias]


class IdentityProvider(unittest.TestCase):
    def test_provider_rendered_with_raw_config_and_sync_mode(self):
        realm = render_realm({"identityProvider": IDP, "teams": TEAMS})
        idp = by_name([{**p, "name": p["alias"]} for p in realm["identityProviders"]], "adfs")
        self.assertEqual(idp["providerId"], "oidc")
        self.assertEqual(idp["displayName"], "ADFS")
        self.assertTrue(idp["enabled"])
        self.assertEqual(idp["config"]["syncMode"], "FORCE")
        self.assertEqual(idp["config"]["clientSecret"], "$(env:ADFS_CLIENT_SECRET)")
        self.assertEqual(idp["config"]["authorizationUrl"], "https://adfs.example.com/adfs/oauth2/authorize")

    def test_disabled_provider_renders_no_idp_keys(self):
        realm = render_realm({"identityProvider": {"enabled": False}, "teams": TEAMS})
        self.assertNotIn("identityProviders", realm)
        self.assertNotIn("identityProviderMappers", realm)

    def test_oidc_attribute_importer_for_groups(self):
        realm = render_realm({"identityProvider": IDP, "teams": TEAMS})
        m = by_name(mappers(realm), "import-groups")
        self.assertEqual(m["identityProviderMapper"], "oidc-user-attribute-idp-mapper")
        self.assertEqual(m["config"], {"syncMode": "FORCE", "claim": "groups", "user.attribute": "groups"})

    def test_saml_attribute_importer_uses_attribute_name_or_friendly_name(self):
        realm = render_realm({"identityProvider": {**IDP, "providerId": "saml"}, "teams": TEAMS})
        m = by_name(mappers(realm), "import-groups")
        self.assertEqual(m["identityProviderMapper"], "saml-user-attribute-idp-mapper")
        self.assertEqual(m["config"]["attribute.name"], "groups")
        realm = render_realm({"identityProvider": {**IDP, "providerId": "saml",
                                                   "groupsAttributeFriendlyName": "Groups"}, "teams": TEAMS})
        m = by_name(mappers(realm), "import-groups")
        self.assertEqual(m["config"]["attribute.friendly.name"], "Groups")
        self.assertNotIn("attribute.name", m["config"])

    def test_one_oidc_group_mapper_per_team_and_ad_group(self):
        realm = render_realm({"identityProvider": IDP, "teams": TEAMS})
        m = by_name(mappers(realm), "team:orders <- AD-Kafka-Orders-Ext")
        self.assertEqual(m["identityProviderMapper"], "oidc-advanced-group-idp-mapper")
        self.assertEqual(m["config"]["group"], "/kafka/orders")
        self.assertEqual(m["config"]["syncMode"], "FORCE")
        self.assertEqual(m["config"]["are.claim.values.regex"], "false")
        self.assertEqual(json.loads(m["config"]["claims"]), [{"key": "groups", "value": "AD-Kafka-Orders-Ext"}])
        names = [m["name"] for m in mappers(realm) if m["name"].startswith("team:")]
        self.assertEqual(sorted(names), ["team:billing <- AD-Kafka-Billing",
                                         "team:orders <- AD-Kafka-Orders",
                                         "team:orders <- AD-Kafka-Orders-Ext"])

    def test_saml_group_mapper_uses_attributes_key(self):
        realm = render_realm({"identityProvider": {**IDP, "providerId": "saml"}, "teams": TEAMS})
        m = by_name(mappers(realm), "team:billing <- AD-Kafka-Billing")
        self.assertEqual(m["identityProviderMapper"], "saml-advanced-group-idp-mapper")
        self.assertEqual(m["config"]["are.attribute.values.regex"], "false")
        self.assertEqual(json.loads(m["config"]["attributes"]), [{"key": "groups", "value": "AD-Kafka-Billing"}])

    def test_cluster_admins_get_group_mapper(self):
        realm = render_realm({"identityProvider": IDP, "teams": TEAMS,
                              "clusterAdmins": {"adGroups": ["AD-Kafka-Platform"]}})
        m = by_name(mappers(realm), "team:cluster-admins <- AD-Kafka-Platform")
        self.assertEqual(m["config"]["group"], "/kafka/cluster-admins")

    def test_extra_mappers_pass_through_with_alias(self):
        extra = [{"name": "email", "identityProviderMapper": "oidc-user-attribute-idp-mapper",
                  "config": {"syncMode": "FORCE", "claim": "email", "user.attribute": "email"}},
                 {"name": "username", "identityProviderMapper": "oidc-username-idp-mapper",
                  "config": {"syncMode": "FORCE", "template": "${CLAIM.upn}"}}]
        realm = render_realm({"identityProvider": {**IDP, "extraMappers": extra}, "teams": TEAMS})
        m = by_name(mappers(realm), "username")
        self.assertEqual(m["identityProviderAlias"], "adfs")
        self.assertEqual(m["identityProviderMapper"], "oidc-username-idp-mapper")
        self.assertEqual(m["config"], {"syncMode": "FORCE", "template": "${CLAIM.upn}"})


if __name__ == "__main__":
    unittest.main()
