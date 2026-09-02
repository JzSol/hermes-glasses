#!/usr/bin/env python3
"""Select a wireless development iPhone and verify an Adam installation."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


class DeviceSelectionError(ValueError):
    """Raised when CoreDevice state cannot identify one safe destination."""


def _devices(payload: dict[str, Any]) -> list[dict[str, Any]]:
    devices = (payload.get("result") or {}).get("devices") or []
    return [device for device in devices if isinstance(device, dict)]


def _is_developer_enabled(value: Any) -> bool:
    return value is True or str(value).lower() == "enabled"


def _is_wireless_iphone(device: dict[str, Any]) -> bool:
    hardware = device.get("hardwareProperties") or {}
    properties = device.get("deviceProperties") or {}
    connection = device.get("connectionProperties") or {}
    transport = str(connection.get("transportType") or "").lower()
    return (
        hardware.get("deviceType") == "iPhone"
        and connection.get("pairingState") == "paired"
        and _is_developer_enabled(properties.get("developerModeStatus"))
        and transport not in {"", "wired", "usb"}
        and connection.get("tunnelState") != "unavailable"
        and bool(hardware.get("udid"))
        and bool(device.get("identifier"))
    )


def select_wireless_iphone(
    payload: dict[str, Any], requested_identifier: str | None = None
) -> dict[str, str]:
    """Return the one paired Developer Mode iPhone on non-wired transport."""
    all_devices = _devices(payload)
    if requested_identifier:
        matches = [
            device for device in all_devices
            if device.get("identifier") == requested_identifier
        ]
        if not matches:
            raise DeviceSelectionError(
                f"CoreDevice {requested_identifier} was not found"
            )
        candidates = [device for device in matches if _is_wireless_iphone(device)]
        if not candidates:
            transport = (matches[0].get("connectionProperties") or {}).get(
                "transportType", "unavailable"
            )
            raise DeviceSelectionError(
                f"the requested iPhone is not wireless (transport: {transport})"
            )
    else:
        candidates = [
            device for device in all_devices if _is_wireless_iphone(device)
        ]

    if not candidates:
        raise DeviceSelectionError(
            "no paired Developer Mode iPhone is reachable wirelessly; "
            "unplug USB and keep the phone unlocked on the same local network"
        )
    if len(candidates) > 1:
        raise DeviceSelectionError(
            "more than one wireless iPhone is available; pass the intended "
            "CoreDevice identifier"
        )

    device = candidates[0]
    hardware = device["hardwareProperties"]
    properties = device.get("deviceProperties") or {}
    connection = device["connectionProperties"]
    return {
        "identifier": str(device["identifier"]),
        "udid": str(hardware["udid"]),
        "name": str(properties.get("name") or "paired iPhone"),
        "transport": str(connection.get("transportType") or "wireless"),
    }


def confirm_wireless_iphone(
    payload: dict[str, Any], expected_identifier: str, expected_udid: str
) -> dict[str, str]:
    """Revalidate that the selected hardware is still reachable wirelessly."""
    selected = select_wireless_iphone(payload, expected_identifier)
    if selected["udid"] != expected_udid:
        raise DeviceSelectionError(
            "the selected iPhone hardware identity changed during installation"
        )
    return selected


def verify_adam_install(
    payload: dict[str, Any], expected_version: str, expected_build: str
) -> dict[str, str]:
    """Require the installed Adam bundle to match the just-built identity."""
    apps = (payload.get("result") or {}).get("apps") or []
    matches = [
        app for app in apps
        if isinstance(app, dict)
        and app.get("bundleIdentifier") == "com.vandret.adamvoice"
    ]
    if len(matches) != 1:
        raise DeviceSelectionError("Adam is not installed exactly once")
    app = matches[0]
    version = str(app.get("version") or "")
    build = str(app.get("bundleVersion") or "")
    if (version, build) != (expected_version, expected_build):
        raise DeviceSelectionError(
            "installed Adam identity does not match the built app: "
            f"expected {expected_version} ({expected_build}), "
            f"found {version or '?'} ({build or '?'})"
        )
    return {"version": version, "build": build}


def _load(path: str) -> dict[str, Any]:
    with Path(path).open(encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise DeviceSelectionError("CoreDevice JSON root is not an object")
    return value


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    select = subparsers.add_parser("select")
    select.add_argument("json_path")
    select.add_argument("identifier", nargs="?")

    confirm = subparsers.add_parser("confirm")
    confirm.add_argument("json_path")
    confirm.add_argument("identifier")
    confirm.add_argument("udid")

    verify = subparsers.add_parser("verify")
    verify.add_argument("json_path")
    verify.add_argument("version")
    verify.add_argument("build")

    arguments = parser.parse_args(argv)
    try:
        payload = _load(arguments.json_path)
        if arguments.command == "select":
            result = select_wireless_iphone(payload, arguments.identifier)
        elif arguments.command == "confirm":
            result = confirm_wireless_iphone(
                payload, arguments.identifier, arguments.udid
            )
        else:
            result = verify_adam_install(
                payload, arguments.version, arguments.build
            )
    except (OSError, json.JSONDecodeError, DeviceSelectionError) as error:
        print(f"Adam wireless install blocked: {error}", file=sys.stderr)
        return 2
    print(json.dumps(result, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
