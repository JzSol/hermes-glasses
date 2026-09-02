import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "adam_wireless_device", ROOT / "scripts" / "adam-wireless-device.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


def device(identifier, *, transport="localNetwork", name="Jani’s iPhone"):
    return {
        "identifier": identifier,
        "hardwareProperties": {
            "deviceType": "iPhone",
            "udid": "00008130-TEST",
        },
        "deviceProperties": {
            "developerModeStatus": "enabled",
            "name": name,
        },
        "connectionProperties": {
            "pairingState": "paired",
            "transportType": transport,
            "tunnelState": "connected",
        },
    }


class WirelessDeviceSelectionTests(unittest.TestCase):
    def test_selects_non_wired_iphone_and_returns_both_identifiers(self):
        payload = {"result": {"devices": [
            device("wired", transport="wired"),
            device("wireless"),
        ]}}
        selected = MODULE.select_wireless_iphone(payload)
        self.assertEqual(selected["identifier"], "wireless")
        self.assertEqual(selected["udid"], "00008130-TEST")
        self.assertEqual(selected["transport"], "localNetwork")

    def test_explicit_wired_device_is_rejected(self):
        payload = {"result": {"devices": [
            device("phone", transport="wired"),
        ]}}
        with self.assertRaisesRegex(
            MODULE.DeviceSelectionError, "not wireless"
        ):
            MODULE.select_wireless_iphone(payload, "phone")

    def test_multiple_wireless_iphones_require_explicit_identifier(self):
        payload = {"result": {"devices": [device("one"), device("two")]}}
        with self.assertRaisesRegex(
            MODULE.DeviceSelectionError, "more than one"
        ):
            MODULE.select_wireless_iphone(payload)
        self.assertEqual(
            MODULE.select_wireless_iphone(payload, "two")["identifier"],
            "two",
        )

    def test_disabled_developer_mode_is_rejected(self):
        candidate = device("phone")
        candidate["deviceProperties"]["developerModeStatus"] = "disabled"
        with self.assertRaisesRegex(
            MODULE.DeviceSelectionError, "no paired Developer Mode"
        ):
            MODULE.select_wireless_iphone({"result": {"devices": [candidate]}})

    def test_confirmation_rejects_device_that_became_wired(self):
        payload = {"result": {"devices": [
            device("phone", transport="wired"),
        ]}}
        with self.assertRaisesRegex(
            MODULE.DeviceSelectionError, "not wireless"
        ):
            MODULE.confirm_wireless_iphone(
                payload, "phone", "00008130-TEST"
            )

    def test_confirmation_rejects_changed_hardware_identity(self):
        candidate = device("phone")
        candidate["hardwareProperties"]["udid"] = "DIFFERENT-UDID"
        with self.assertRaisesRegex(
            MODULE.DeviceSelectionError, "hardware identity changed"
        ):
            MODULE.confirm_wireless_iphone(
                {"result": {"devices": [candidate]}},
                "phone",
                "00008130-TEST",
            )


class AdamInstallVerificationTests(unittest.TestCase):
    def test_exact_version_and_build_are_accepted(self):
        payload = {"result": {"apps": [{
            "bundleIdentifier": "com.vandret.adamvoice",
            "version": "1.5",
            "bundleVersion": "10",
        }]}}
        self.assertEqual(
            MODULE.verify_adam_install(payload, "1.5", "10"),
            {"version": "1.5", "build": "10"},
        )

    def test_wrong_installed_build_is_rejected(self):
        payload = {"result": {"apps": [{
            "bundleIdentifier": "com.vandret.adamvoice",
            "version": "1.5",
            "bundleVersion": "9",
        }]}}
        with self.assertRaisesRegex(
            MODULE.DeviceSelectionError, "does not match"
        ):
            MODULE.verify_adam_install(payload, "1.5", "10")


if __name__ == "__main__":
    unittest.main()
