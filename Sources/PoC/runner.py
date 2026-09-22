#!/usr/bin/env python3
"""Run the bundled upstream Airlift PoC, extending device selection to iPad."""
from copy import deepcopy
import importlib.util
from pathlib import Path
import sys
sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("upstream_airlift", ROOT / "airlift.py")
airlift = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(airlift)

airlift.DEVICE_HELPER = ROOT.parents[1] / "Helpers" / "poc_device_helper"
airlift.AIRTRAFFIC_HOST = ROOT.parents[1] / "Helpers" / "airtraffic_host"
upstream_available_devices = airlift.available_devices


def available_devices(devices):
    # Upstream limits discovery to iPhone although the same paired-device
    # services exist on iPad. Keep every other physical/pairing check intact.
    candidates = deepcopy(devices)
    products = {}
    for device in candidates:
        hardware = device.get("hardwareProperties") or device.get("properties", {}).get("hardware", {})
        product = hardware.get("productType")
        udid = hardware.get("udid")
        if isinstance(product, str) and product.startswith("iPad"):
            products[udid] = product
            hardware["productType"] = "iPhone" + product[4:]
    matches = upstream_available_devices(candidates)
    for match in matches:
        if match["udid"] in products:
            match["product"] = products[match["udid"]]
    return matches


airlift.available_devices = available_devices
raise SystemExit(airlift.main())
