#!/usr/bin/env python3
from pathlib import Path
import plistlib
import xml.etree.ElementTree as ET

ANDROID_FORBIDDEN = (
    "android.permission.BLUETOOTH_ADVERTISE", "android.permission.BLUETOOTH_SCAN",
    "android.permission.BLUETOOTH_CONNECT", "android.permission.NEARBY_WIFI_DEVICES",
    "android.permission.ACCESS_FINE_LOCATION", "android.permission.RECORD_AUDIO",
    "FOREGROUND_SERVICE_CONNECTED_DEVICE", "io.godstone.mesh.MeshService",
    'android:screenOrientation="portrait"', 'android:largeHeap="true"',
)
IOS_FORBIDDEN_KEYS = {
    "NSBluetoothAlwaysUsageDescription", "NSLocalNetworkUsageDescription",
    "NSMicrophoneUsageDescription", "NSCameraUsageDescription",
    "NSLocationWhenInUseUsageDescription", "UIBackgroundModes", "NSBonjourServices",
    "UIUserInterfaceStyle",
}


def main() -> int:
    errors: list[str] = []
    manifest = Path("android/app/src/main/AndroidManifest.xml")
    try:
        ET.parse(manifest)
        text = manifest.read_text(encoding="utf-8")
    except Exception as exc:
        errors.append(f"Android manifest invalid: {exc}")
        text = ""
    for needle in ANDROID_FORBIDDEN:
        if needle in text:
            errors.append(f"Android disabled capability remains: {needle}")
    for path in (Path("ios/Godstone/Info.plist"), Path("ios/Godstone/Godstone.entitlements"), Path("ios/Godstone/PrivacyInfo.xcprivacy")):
        try:
            with path.open("rb") as stream:
                value = plistlib.load(stream)
        except Exception as exc:
            errors.append(f"{path}: invalid plist: {exc}")
            continue
        if path.name == "Info.plist":
            for key in IOS_FORBIDDEN_KEYS:
                if key in value:
                    errors.append(f"iOS disabled capability remains: {key}")
        if path.name == "Godstone.entitlements" and value:
            errors.append("iOS release entitlements must be empty for Archive-only release")
    project = Path("ios/project.yml").read_text(encoding="utf-8")
    if "PRODUCT_BUNDLE_IDENTIFIER: io.godstone.app" not in project:
        errors.append("single iOS bundle identity missing")
    if "LightRelease: release" not in project or "archive:\n      config: LightRelease" not in project:
        errors.append("iOS archive scheme is not a genuine release configuration")
    if errors:
        print("Release surface check failed:\n" + "\n".join(errors))
        return 1
    print("release permissions, entitlements, identities, and schemes are minimized")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
