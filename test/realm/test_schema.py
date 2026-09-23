import unittest

from helpers import render_error, render_realm


class ValuesSchema(unittest.TestCase):
    def test_typo_in_team_key_is_rejected(self):
        err = render_error({"teams": {"t": {"adGroup": ["x"]}}})
        self.assertIn("adGroup", err)

    def test_unknown_provider_id_is_rejected(self):
        err = render_error({"identityProvider": {"enabled": True, "providerId": "ldap"}})
        self.assertIn("providerId", err)

    def test_grant_without_role_is_rejected(self):
        err = render_error({"teams": {"t": {"grants": [{"topics": ["a"]}]}}})
        self.assertIn("role", err)

    def test_ad_groups_must_be_strings(self):
        err = render_error({"teams": {"t": {"adGroups": [42]}}})
        self.assertIn("adGroups", err)

    def test_client_without_name_is_rejected(self):
        err = render_error({"clients": [{"redirectUris": ["x"]}]})
        self.assertIn("name", err)

    def test_valid_full_values_pass(self):
        render_realm({"teams": {"t": {"description": "d", "adGroups": ["x"],
                                      "owns": {"topics": ["a"], "consumerGroups": ["b"], "transactionalIds": ["c"]},
                                      "grants": [{"role": "topic-reader", "topics": ["z"], "cluster": True}]}},
                      "clients": [{"name": "ui", "redirectUris": ["u"], "secretEnv": "S", "serviceAccount": True,
                                   "attributes": {"a": "b"}, "extra": {"x": 1}}]})


if __name__ == "__main__":
    unittest.main()
