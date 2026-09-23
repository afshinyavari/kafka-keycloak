import unittest

from helpers import render_realm


class RealmBasics(unittest.TestCase):
    def test_realm_name_and_enabled(self):
        realm = render_realm({"realm": {"name": "kafka-dev"}})
        self.assertEqual(realm["realm"], "kafka-dev")
        self.assertTrue(realm["enabled"])

    def test_display_name_and_raw_settings_are_merged(self):
        realm = render_realm({"realm": {"displayName": "Kafka (dev)",
                                        "settings": {"ssoSessionIdleTimeout": 1800}}})
        self.assertEqual(realm["displayName"], "Kafka (dev)")
        self.assertEqual(realm["ssoSessionIdleTimeout"], 1800)

    def test_no_secret_like_values_in_realm(self):
        # Secrets must only ever appear as $(env:...) references.
        realm = render_realm({"kafka": {"secretEnv": "KAFKA_CLIENT_SECRET"}})
        kafka = [c for c in realm["clients"] if c["clientId"] == "kafka"][0]
        self.assertEqual(kafka["secret"], "$(env:KAFKA_CLIENT_SECRET)")


if __name__ == "__main__":
    unittest.main()
