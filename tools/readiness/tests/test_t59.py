#! /usr/bin/env python3
"""T59 readiness court: the platform permission and background-capability truth.

The card's law, one witness each where the rule speaketh:

  W01 the matrix is resolved from FACTS, not from a platform name: the four
      states a user meeteth, each with a TYPED reason for every refusal
  W02 THE NAMED NEGATIVE, first limb: iOS CENTRAL is never forced from the
      platform -- the role cometh from the hint, and a central-role iOS device in
      the background is refused by name
  W03 THE NAMED NEGATIVE, second limb: background availability is never claimed
      INDEPENDENT of the hint role -- the two orientations differ measurably
  W04 permission deny / permanent deny / revoke / restore, each with its own
      reason, and a permanently-denied permission is NOT requestable
  W05 the power toggle: off and UNKNOWN both refuse (and an unknown never guesseth)
  W06 a force quit is UNSUPPORTED, not degraded: nothing runs and no restoration
      is promised
  W07 no scan from a stopped state
  W08 Android's background road is the foreground service, and its absence is
      refused by name
  W09 a LOCKED protected store carrieth no custody claim while the radio may run
  W10 the LIGHT profile carrieth NO radio capability at all, whatever the facts
  W11 the MANIFESTS agree with the matrix: the shipping Android manifest declares
      no Bluetooth permission, the lab does, and the iOS app declares no
      background mode
  W12 the ADR's own prose agreeth with the matrix: the documented asymmetry is the
      one the model encodeth (never a promise the platform cannot keep)
  W13 the matrix's decisions are TOTAL: every combination of the six facts
      resolveth to a verdict with a reason, and no combination crash

No external gate is closed by any witness; readiness stays false; the physical
matrix stays external (T73-T75). This court proveth the MODEL and the
DECLARATIONS, not a radio.
"""
from __future__ import annotations

import itertools
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "readiness"))

from capabilities import (  # noqa: E402
    AppState, Authorization, CapabilityInputs, HintRole, Platform, Power,
    Profile, ProtectedData, RefusalReason, capability_state,
)


class T59MatrixTest(unittest.TestCase):
    """W01-W03 -- the matrix, and the two limbs of the named negative."""

    def test_w01_the_matrix_is_resolved_from_facts(self):
        # a healthy foreground iOS device, both roles
        both = capability_state(CapabilityInputs(Platform.IOS, hint_role=HintRole.BOTH))
        self.assertTrue(both.advertise)
        self.assertTrue(both.scan)
        self.assertTrue(both.radio_available)
        self.assertEqual(both.advertise.reason, None)
        self.assertIn("radio is available", both.explain())

        # a peripheral-role device does not scan; a central-role one does not advertise
        peripheral = capability_state(CapabilityInputs(Platform.IOS, hint_role=HintRole.PERIPHERAL))
        self.assertTrue(peripheral.advertise)
        self.assertFalse(peripheral.scan)
        self.assertEqual(peripheral.scan.reason, RefusalReason.HINT_ROLE_DOES_NOT_ASK)
        self.assertIn("does not scan", peripheral.scan.detail)

        central = capability_state(CapabilityInputs(Platform.IOS, hint_role=HintRole.CENTRAL))
        self.assertFalse(central.advertise)
        self.assertEqual(central.advertise.reason, RefusalReason.HINT_ROLE_DOES_NOT_ASK)
        self.assertTrue(central.scan)
        # a peripheral waiteth; it does not initiate
        self.assertFalse(peripheral.connect)
        self.assertEqual(peripheral.connect.reason, RefusalReason.HINT_ROLE_DOES_NOT_ASK)

    def test_w02_ios_central_is_never_forced_from_the_platform(self):
        """THE NAMED NEGATIVE, first limb."""
        # the SAME platform, the SAME state, two hint roles: the verdicts differ
        central = capability_state(CapabilityInputs(
            Platform.IOS, app_state=AppState.BACKGROUND, hint_role=HintRole.CENTRAL))
        peripheral = capability_state(CapabilityInputs(
            Platform.IOS, app_state=AppState.BACKGROUND, hint_role=HintRole.PERIPHERAL))

        self.assertFalse(central.scan, "iOS may not discover in the background")
        self.assertEqual(central.scan.reason,
                         RefusalReason.IOS_BACKGROUND_CENTRAL_UNSUPPORTED)
        self.assertIn("cannot discover peripherals in the background", central.scan.detail)
        self.assertFalse(central.background_discovery)
        self.assertIn("remaineth unavailable", central.explain())

        # ... and the peripheral orientation is NOT refused by that rule: the
        # capability followeth the HINT, not the platform name
        self.assertTrue(peripheral.advertise)
        self.assertNotEqual(peripheral.background_discovery.reason,
                            RefusalReason.IOS_BACKGROUND_CENTRAL_UNSUPPORTED)
        self.assertIn("peripheral", peripheral.explain())

        # a platform-based forcing is refusable BY NAME: the platform is IDENTICAL
        # in both cases, and only the HINT differeth -- so the verdicts must differ
        # (the first form of this assertion compared the two SCAN verdicts, which
        # are both false for unrelated reasons, and proved nothing)
        self.assertNotEqual(central.advertise.allowed, peripheral.advertise.allowed,
                            "the platform alone must not decide the role")
        self.assertNotEqual(central.scan.reason, peripheral.scan.reason,
                            "and the REFUSAL differeth: a central is refused by the iOS "
                            "background rule, a peripheral because it does not scan")

    def test_w03_background_availability_is_never_independent_of_the_hint(self):
        """THE NAMED NEGATIVE, second limb."""
        orientation_advertise = {}
        orientation_scan = {}
        for role in (HintRole.CENTRAL, HintRole.PERIPHERAL, HintRole.BOTH):
            state = capability_state(CapabilityInputs(
                Platform.IOS, app_state=AppState.BACKGROUND, hint_role=role))
            orientation_advertise[role] = state.advertise.allowed
            orientation_scan[role] = state.scan.allowed
        self.assertEqual(orientation_advertise[HintRole.CENTRAL], False)
        self.assertEqual(orientation_advertise[HintRole.PERIPHERAL], True)
        self.assertEqual(orientation_scan[HintRole.PERIPHERAL], False)
        self.assertEqual(orientation_scan[HintRole.BOTH], True)
        # a central's scan is refused by the iOS BACKGROUND rule, not by the role:
        # the reason is what proveth the asymmetry, and it differeth from the
        # peripheral's role refusal
        central_state = capability_state(CapabilityInputs(
            Platform.IOS, app_state=AppState.BACKGROUND, hint_role=HintRole.CENTRAL))
        self.assertEqual(central_state.scan.reason,
                         RefusalReason.IOS_BACKGROUND_CENTRAL_UNSUPPORTED)
        # ... and no single flag could express all three: the two maps differ
        self.assertNotEqual(orientation_advertise, orientation_scan,
                            "a single 'background is available' flag would hide the asymmetry")
        self.assertGreater(len(set(orientation_advertise.values())), 1)
        self.assertGreater(len(set(orientation_scan.values())), 1)


class T59PermissionTest(unittest.TestCase):
    """W04-W07 -- authorization, power, force quit, stopped."""

    def test_w04_deny_permanent_deny_revoke_restore(self):
        granted = capability_state(CapabilityInputs(Platform.ANDROID, authorization=Authorization.GRANTED))
        self.assertTrue(granted.radio_available)

        denied = capability_state(CapabilityInputs(Platform.ANDROID, authorization=Authorization.DENIED))
        self.assertFalse(denied.radio_available)
        self.assertEqual(denied.scan.reason, RefusalReason.PERMISSION_NOT_GRANTED)
        self.assertIn("denied", denied.explain())

        permanent = capability_state(CapabilityInputs(
            Platform.ANDROID, authorization=Authorization.PERMANENTLY_DENIED))
        self.assertFalse(permanent.radio_available)
        self.assertEqual(permanent.scan.reason, RefusalReason.PERMISSION_PERMANENTLY_DENIED)
        self.assertIn("Settings", permanent.explain())

        restricted = capability_state(CapabilityInputs(
            Platform.ANDROID, authorization=Authorization.RESTRICTED))
        self.assertFalse(restricted.radio_available)
        self.assertEqual(restricted.scan.reason, RefusalReason.PERMISSION_RESTRICTED)

        not_determined = capability_state(CapabilityInputs(
            Platform.ANDROID, authorization=Authorization.NOT_DETERMINED))
        self.assertEqual(not_determined.scan.reason, RefusalReason.PERMISSION_NOT_REQUESTED)

        # REQUESTABILITY: only a plain denial or an unasked permission may be asked
        self.assertTrue(denied.permission_requestable)
        self.assertTrue(not_determined.permission_requestable)
        self.assertFalse(permanent.permission_requestable,
                         "a permanently-denied permission is not re-requestable")
        self.assertFalse(restricted.permission_requestable)
        self.assertFalse(granted.permission_requestable, "nothing to ask for")
        # a REVOKE mid-session returneth to the refused state with the same reason
        revoked = capability_state(CapabilityInputs(Platform.ANDROID, authorization=Authorization.DENIED))
        self.assertEqual(revoked.scan.reason, denied.scan.reason)
        # and a RESTORE returneth every verdict
        restored = capability_state(CapabilityInputs(Platform.ANDROID, authorization=Authorization.GRANTED))
        self.assertTrue(restored.advertise and restored.scan and restored.connect)

    def test_w05_the_power_toggle_refuseth_both_ways(self):
        off = capability_state(CapabilityInputs(Platform.ANDROID, power=Power.OFF))
        self.assertFalse(off.radio_available)
        self.assertEqual(off.scan.reason, RefusalReason.RADIO_POWERED_OFF)
        self.assertIn("Bluetooth is off", off.explain())

        unknown = capability_state(CapabilityInputs(Platform.ANDROID, power=Power.UNKNOWN))
        self.assertFalse(unknown.radio_available,
                         "an UNKNOWN power state never guesseth")
        self.assertEqual(unknown.scan.reason, RefusalReason.RADIO_POWER_UNKNOWN)
        self.assertIn("UNKNOWN", unknown.explain())

        on = capability_state(CapabilityInputs(Platform.ANDROID, power=Power.ON))
        self.assertTrue(on.radio_available)
        # toggling back restoreth the same verdicts
        self.assertEqual(on.advertise.to_dict(), capability_state(
            CapabilityInputs(Platform.ANDROID, power=Power.ON)).advertise.to_dict())

    def test_w06_a_force_quit_is_unsupported(self):
        force_quit = capability_state(CapabilityInputs(
            Platform.IOS, app_state=AppState.FORCE_QUIT))
        self.assertFalse(force_quit.radio_available)
        self.assertEqual(force_quit.advertise.reason, RefusalReason.FORCE_QUIT_UNSUPPORTED)
        self.assertFalse(force_quit.restoration_supported,
                         "force quit promiseth NO restoration")
        self.assertIn("force quit", force_quit.explain())
        self.assertIn("cannot restore", force_quit.explain())

        # a backgrounded iOS process DOES support restoration: the distinction is
        # the difference between a platform feature and a promise it cannot keep
        backgrounded = capability_state(CapabilityInputs(
            Platform.IOS, app_state=AppState.BACKGROUND, hint_role=HintRole.PERIPHERAL))
        self.assertTrue(backgrounded.restoration_supported)
        self.assertFalse(force_quit.restoration_supported)

    def test_w07_no_scan_from_a_stopped_state(self):
        stopped = capability_state(CapabilityInputs(Platform.IOS, app_state=AppState.STOPPED))
        self.assertFalse(stopped.scan)
        self.assertFalse(stopped.advertise)
        self.assertFalse(stopped.connect)
        self.assertEqual(stopped.scan.reason, RefusalReason.PROCESS_STOPPED)
        self.assertIn("stopped", stopped.explain())
        # a stopped process is NOT a force quit: the reasons differ, so a screen
        # can say the right thing
        self.assertNotEqual(stopped.scan.reason, RefusalReason.FORCE_QUIT_UNSUPPORTED)


class T59PlatformAndProfileTest(unittest.TestCase):
    """W08-W10 -- Android's service, the locked store, and the LIGHT profile."""

    def test_w08_android_background_needeth_its_foreground_service(self):
        without = capability_state(CapabilityInputs(
            Platform.ANDROID, app_state=AppState.BACKGROUND))
        self.assertFalse(without.background_discovery)
        self.assertEqual(without.background_discovery.reason,
                         RefusalReason.ANDROID_BACKGROUND_NEEDS_FOREGROUND_SERVICE)
        self.assertFalse(without.scan)
        self.assertIn("foreground service", without.background_discovery.detail)

        with_service = capability_state(CapabilityInputs(
            Platform.ANDROID, app_state=AppState.BACKGROUND,
            android_foreground_service=True))
        self.assertTrue(with_service.background_discovery)
        self.assertTrue(with_service.scan)
        # ... and Android promiseth NO process restoration either: only iOS has it
        self.assertFalse(with_service.restoration_supported)

    def test_w09_a_locked_store_carrieth_no_custody_claim(self):
        locked = capability_state(CapabilityInputs(
            Platform.IOS, protected_data=ProtectedData.UNAVAILABLE,
            hint_role=HintRole.PERIPHERAL))
        self.assertTrue(locked.advertise, "the radio may run while the device is locked")
        self.assertFalse(locked.keychain_write, "but no key material may be written")
        self.assertEqual(locked.keychain_write.reason,
                         RefusalReason.PROTECTED_DATA_UNAVAILABLE)
        self.assertIn("locked", locked.keychain_write.detail)

        unlocked = capability_state(CapabilityInputs(Platform.IOS, hint_role=HintRole.PERIPHERAL))
        self.assertTrue(unlocked.keychain_write)
        self.assertNotEqual(locked.keychain_write.allowed, unlocked.keychain_write.allowed)

    def test_w10_the_light_profile_carrieth_no_radio_capability(self):
        # EVERY fact granted, and the LIGHT profile still refuseth
        light = capability_state(CapabilityInputs(
            Platform.ANDROID, profile=Profile.LIGHT, authorization=Authorization.GRANTED,
            power=Power.ON, app_state=AppState.FOREGROUND, hint_role=HintRole.BOTH,
            android_foreground_service=True))
        self.assertFalse(light.radio_available)
        for verdict in (light.advertise, light.scan, light.connect,
                        light.background_discovery):
            self.assertEqual(verdict.reason, RefusalReason.PROFILE_CARRIES_NO_RADIO)
        self.assertIn("Archive-only", light.explain())
        self.assertIn("no Bluetooth permission", light.explain())
        # an over-claiming LIGHT build is therefore impossible to describe
        self.assertFalse(light.to_dict()["radio_available"])


class T59DeclarationsTest(unittest.TestCase):
    """W11-W13 -- the manifests, the ADR's prose, and totality."""

    def test_w11_the_manifests_agree_with_the_matrix(self):
        shipping = (ROOT / "android/app/src/main/AndroidManifest.xml").read_text(encoding="utf-8")
        lab = (ROOT / "android/labmesh/src/main/AndroidManifest.xml").read_text(encoding="utf-8")
        info_plist = (ROOT / "ios/Godstone/Info.plist").read_text(encoding="utf-8")
        entitlements = (ROOT / "ios/Godstone/Godstone.entitlements").read_text(encoding="utf-8")

        # the SHIPPING build declares none of the radio permissions the matrix
        # requireth, so its Profile.LIGHT verdict is a fact about the manifest
        for permission in ("android.permission.BLUETOOTH_ADVERTISE",
                           "android.permission.BLUETOOTH_SCAN",
                           "android.permission.BLUETOOTH_CONNECT"):
            self.assertNotIn(permission, shipping,
                             f"the shipping manifest must not declare {permission}")
            self.assertIn(permission, lab,
                          f"the lab manifest must declare {permission}")

        # the iOS shipping app declares no background mode and no Bluetooth usage
        self.assertNotIn("UIBackgroundModes", info_plist)
        self.assertNotIn("NSBluetoothAlwaysUsageDescription", info_plist)
        self.assertNotIn("bluetooth-peripheral", entitlements)
        self.assertIn("<dict/>", entitlements.replace(" ", "").replace("\n", ""),
                      "the shipping entitlements are empty")

        # ... which is exactly what the matrix sayeth for those profiles
        shipping_state = capability_state(CapabilityInputs(Platform.ANDROID, profile=Profile.LIGHT))
        self.assertFalse(shipping_state.radio_available)
        ios_shipping = capability_state(CapabilityInputs(Platform.IOS, profile=Profile.LIGHT))
        self.assertFalse(ios_shipping.radio_available)

    def test_w12_the_adr_prose_agreeth_with_the_matrix(self):
        adr = (ROOT / "docs/adr/ADR-002-ble-record-layer.md").read_text(encoding="utf-8")
        # the ADR states the asymmetry; the model must encode THAT, not a promise
        self.assertIn("background-discovery limitation", adr)
        self.assertIn("cannot discover peripherals", adr)
        self.assertIn("NOT CLOSED", adr)
        central = capability_state(CapabilityInputs(
            Platform.IOS, app_state=AppState.BACKGROUND, hint_role=HintRole.CENTRAL))
        self.assertIn("cannot discover peripherals in the background", central.scan.detail)
        # and section 19 promiseth no force-quit schedule: the model refuseth it
        section = (ROOT / "docs/production-readiness/sections/19.md").read_text(encoding="utf-8")
        self.assertIn("force-quit", section)
        force_quit = capability_state(CapabilityInputs(Platform.IOS, app_state=AppState.FORCE_QUIT))
        self.assertEqual(force_quit.advertise.reason, RefusalReason.FORCE_QUIT_UNSUPPORTED)

    def test_w13_the_matrix_is_total(self):
        facts = {
            "platform": list(Platform),
            "profile": list(Profile),
            "authorization": list(Authorization),
            "power": list(Power),
            "app_state": list(AppState),
            "protected_data": list(ProtectedData),
            "hint_role": list(HintRole),
            "android_foreground_service": [True, False],
        }
        keys = list(facts)
        checked = 0
        for values in itertools.product(*(facts[k] for k in keys)):
            inputs = CapabilityInputs(**dict(zip(keys, values)))
            state = capability_state(inputs)
            checked += 1
            for verdict in (state.advertise, state.scan, state.connect,
                            state.background_discovery, state.keychain_write):
                if not verdict.allowed:
                    self.assertIsNotNone(verdict.reason,
                                         f"a refusal must carry a reason: {inputs}")
                    self.assertTrue(verdict.detail, f"and words: {inputs}")
            self.assertTrue(state.explain(), "every state explaineth itself")
            # THE INVARIANT: a LIGHT build never claimeth a radio capability
            if inputs.profile is Profile.LIGHT:
                self.assertFalse(state.radio_available, f"LIGHT must claim nothing: {inputs}")
            # and a force quit never claimeth restoration
            if inputs.app_state is AppState.FORCE_QUIT:
                self.assertFalse(state.restoration_supported)
        self.assertEqual(checked, 2 * 2 * 5 * 3 * 4 * 2 * 3 * 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
