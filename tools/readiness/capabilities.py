#!/usr/bin/env python3
"""The platform capability matrix (T59).

"iOS background discovery is asymmetric; old role documentation promises
unsupported behavior and manifests need profile-specific permissions."

This module is the ONE place that answers "may this build do this, right now, on
this platform?" -- and it answers from FACTS a platform actually hands us, never
from a device model, a platform name or a hopeful default:

    OS authorization   granted / denied / permanently_denied / restricted / not_determined
    radio power        on / off / unknown
    app state          foreground / background / stopped / force_quit
    protected data     available / unavailable
    profile            LIGHT (carrieth no radio capability) / LABMESH
    hint role          peripheral / central / both -- the ELECTION's hint, never
                       the platform

LAWS, each witnessed by the T59 court:

  1. THE ROLE COMETH FROM THE HINT, NEVER FROM THE PLATFORM. iOS may advertise
     from the background when the election's hint maketh us the PERIPHERAL, and
     may NOT scan for peripherals in the background when it maketh us the CENTRAL
     (Apple's own limitation, ADR-002). Any capability derived from "this is an
     iPhone" rather than from the hint is a LIE.
  2. NO SCAN FROM A STOPPED STATE. A stopped or force-quit process scans nothing.
     Force quit is UNSUPPORTED, not merely degraded: no state restoration is
     promised, and the matrix sayeth so rather than promising a resume.
  3. A PERMANENTLY-DENIED PERMISSION IS NOT REQUESTABLE. Only Settings changeth
     it; asking again is a no-op the user never seeth.
  4. A LOCKED PROTECTED STORE CARRIETH NO CUSTODY CLAIM. The radio may run while
     the device is locked; the keychain may not be written.
  5. THE LIGHT PROFILE CARRIETH NO RADIO CAPABILITY AT ALL. It declares no
     Bluetooth permission and no background mode, so every radio verdict for it is
     REFUSED -- a build that cannot ask may not claim.

Every verdict carrieth a TYPED reason, so a screen can explain itself instead of
failing mutely, and so a court can assert a refusal BY NAME.
"""
from __future__ import annotations

from dataclasses import dataclass, replace
from enum import Enum

__all__ = [
    "Platform", "Profile", "Authorization", "Power", "AppState", "ProtectedData",
    "HintRole", "Verdict", "RefusalReason", "CapabilityInputs", "CapabilityState",
    "capability_state", "describe_matrix",
]


class Platform(str, Enum):
    ANDROID = "android"
    IOS = "ios"


class Profile(str, Enum):
    """The LIGHT Archive-only release, or the nonshipping lab."""
    LIGHT = "LIGHT"
    LABMESH = "LABMESH"


class Authorization(str, Enum):
    GRANTED = "granted"
    DENIED = "denied"
    PERMANENTLY_DENIED = "permanently_denied"
    RESTRICTED = "restricted"
    NOT_DETERMINED = "not_determined"


class Power(str, Enum):
    ON = "on"
    OFF = "off"
    UNKNOWN = "unknown"


class AppState(str, Enum):
    FOREGROUND = "foreground"
    BACKGROUND = "background"
    STOPPED = "stopped"
    FORCE_QUIT = "force_quit"


class ProtectedData(str, Enum):
    AVAILABLE = "available"
    UNAVAILABLE = "unavailable"


class HintRole(str, Enum):
    """The role the ELECTION assigned from the hint -- never the platform."""
    PERIPHERAL = "peripheral"
    CENTRAL = "central"
    BOTH = "both"


class RefusalReason(str, Enum):
    PROFILE_CARRIES_NO_RADIO = "profile_carries_no_radio"
    PERMISSION_NOT_GRANTED = "permission_not_granted"
    PERMISSION_PERMANENTLY_DENIED = "permission_permanently_denied"
    PERMISSION_RESTRICTED = "permission_restricted"
    PERMISSION_NOT_REQUESTED = "permission_not_requested"
    RADIO_POWERED_OFF = "radio_powered_off"
    RADIO_POWER_UNKNOWN = "radio_power_unknown"
    PROCESS_STOPPED = "process_stopped"
    FORCE_QUIT_UNSUPPORTED = "force_quit_unsupported"
    IOS_BACKGROUND_CENTRAL_UNSUPPORTED = "ios_background_central_unsupported"
    ANDROID_BACKGROUND_NEEDS_FOREGROUND_SERVICE = "android_background_needs_foreground_service"
    HINT_ROLE_DOES_NOT_ASK = "hint_role_does_not_ask"
    PROTECTED_DATA_UNAVAILABLE = "protected_data_unavailable"


@dataclass(frozen=True)
class Verdict:
    """One answer: allowed, or refused with a typed reason and honest words."""
    allowed: bool
    reason: RefusalReason | None = None
    detail: str = ""

    def __bool__(self) -> bool:  # a verdict is truthy iff allowed
        return self.allowed

    def to_dict(self) -> dict:
        return {"allowed": self.allowed,
                "reason": self.reason.value if self.reason else None,
                "detail": self.detail}


_ALLOWED = Verdict(True)


def _refuse(reason: RefusalReason, detail: str) -> Verdict:
    return Verdict(False, reason, detail)


@dataclass(frozen=True)
class CapabilityInputs:
    platform: Platform
    profile: Profile = Profile.LABMESH
    authorization: Authorization = Authorization.GRANTED
    power: Power = Power.ON
    app_state: AppState = AppState.FOREGROUND
    protected_data: ProtectedData = ProtectedData.AVAILABLE
    hint_role: HintRole = HintRole.BOTH
    # Android's supported background road is a foreground service of type
    # connectedDevice; without one, background is refused there too.
    android_foreground_service: bool = False


@dataclass(frozen=True)
class CapabilityState:
    """What this build may do RIGHT NOW, with a reason for every refusal."""
    inputs: CapabilityInputs
    advertise: Verdict
    scan: Verdict
    connect: Verdict
    background_discovery: Verdict
    keychain_write: Verdict
    permission_requestable: bool

    @property
    def radio_available(self) -> bool:
        """True iff ANY radio work is possible at all."""
        return bool(self.advertise) or bool(self.scan) or bool(self.connect)

    @property
    def restoration_supported(self) -> bool:
        """
        True iff the platform may restore this process's radio state. A FORCE QUIT
        is not a state a restoration promiseth: the OS will not relaunch us for a
        peripheral event, and claiming otherwise is the documented lie this module
        existeth to prevent.
        """
        if self.inputs.app_state is AppState.FORCE_QUIT:
            return False
        return self.inputs.platform is Platform.IOS

    def explain(self) -> str:
        """The honest one-line words for the screen (or for a log)."""
        if self.inputs.app_state is AppState.FORCE_QUIT:
            return ("The app was force quit. It cannot restore radio work until you open it "
                    "again; queued messages wait on this phone.")
        if self.inputs.profile is Profile.LIGHT:
            return ("This build is Archive-only and carries no radio capability: it declares "
                    "no Bluetooth permission, so messages are not sent from it.")
        if not self.radio_available:
            for verdict in (self.advertise, self.scan, self.connect):
                if verdict.reason is not None:
                    return verdict.detail or verdict.reason.value
        if self.inputs.app_state is AppState.BACKGROUND and self.inputs.platform is Platform.IOS:
            if self.inputs.hint_role is HintRole.CENTRAL:
                return self.scan.detail
            return ("Running in the background as the peripheral the election chose: peers may "
                    "reach us, but we do not scan for them.")
        return "The radio is available."

    def to_dict(self) -> dict:
        return {
            "platform": self.inputs.platform.value,
            "profile": self.inputs.profile.value,
            "hint_role": self.inputs.hint_role.value,
            "app_state": self.inputs.app_state.value,
            "advertise": self.advertise.to_dict(),
            "scan": self.scan.to_dict(),
            "connect": self.connect.to_dict(),
            "background_discovery": self.background_discovery.to_dict(),
            "keychain_write": self.keychain_write.to_dict(),
            "permission_requestable": self.permission_requestable,
            "restoration_supported": self.restoration_supported,
            "radio_available": self.radio_available,
            "explanation": self.explain(),
        }


def _radio_gate(inputs: CapabilityInputs) -> Verdict | None:
    """The gates that stoppeth ALL radio work; None when the radio may run."""
    if inputs.profile is Profile.LIGHT:
        return _refuse(
            RefusalReason.PROFILE_CARRIES_NO_RADIO,
            "This build is Archive-only: it declares no Bluetooth permission, so it cannot "
            "advertise, scan or connect.",
        )
    if inputs.app_state is AppState.FORCE_QUIT:
        return _refuse(
            RefusalReason.FORCE_QUIT_UNSUPPORTED,
            "The app was force quit; no radio work and no restoration is promised until it is "
            "opened again.",
        )
    if inputs.app_state is AppState.STOPPED:
        return _refuse(
            RefusalReason.PROCESS_STOPPED,
            "The process is stopped; it neither advertises nor scans.",
        )
    if inputs.power is Power.OFF:
        return _refuse(
            RefusalReason.RADIO_POWERED_OFF,
            "Bluetooth is off on this device, so no radio work is possible.",
        )
    if inputs.power is Power.UNKNOWN:
        return _refuse(
            RefusalReason.RADIO_POWER_UNKNOWN,
            "The radio's power state is UNKNOWN; the app refuseth rather than guess.",
        )
    if inputs.authorization is Authorization.PERMANENTLY_DENIED:
        return _refuse(
            RefusalReason.PERMISSION_PERMANENTLY_DENIED,
            "The nearby-devices permission was permanently denied. Only Settings can change "
            "it; asking again would do nothing.",
        )
    if inputs.authorization is Authorization.RESTRICTED:
        return _refuse(
            RefusalReason.PERMISSION_RESTRICTED,
            "The nearby-devices permission is restricted on this device and cannot be granted "
            "by the user.",
        )
    if inputs.authorization is Authorization.DENIED:
        return _refuse(
            RefusalReason.PERMISSION_NOT_GRANTED,
            "The nearby-devices permission was denied; the app cannot reach the radio.",
        )
    if inputs.authorization is Authorization.NOT_DETERMINED:
        return _refuse(
            RefusalReason.PERMISSION_NOT_REQUESTED,
            "The nearby-devices permission has not been requested yet.",
        )
    return None


def capability_state(inputs: CapabilityInputs) -> CapabilityState:
    """Resolve what this build may do, with a reason for every refusal."""
    blocked = _radio_gate(inputs)

    def role_allows(role: HintRole) -> bool:
        return inputs.hint_role in (role, HintRole.BOTH)

    # THE ROLE COMETH FROM THE HINT. It is never derived from the platform: an
    # iPhone is not "the central", and an Android phone is not "the peripheral".
    advertise = _ALLOWED if role_allows(HintRole.PERIPHERAL) else _refuse(
        RefusalReason.HINT_ROLE_DOES_NOT_ASK,
        "The election's hint made this device the CENTRAL, so it does not advertise.",
    )
    scan = _ALLOWED if role_allows(HintRole.CENTRAL) else _refuse(
        RefusalReason.HINT_ROLE_DOES_NOT_ASK,
        "The election's hint made this device the PERIPHERAL, so it does not scan.",
    )
    connect = _ALLOWED if inputs.hint_role is not HintRole.PERIPHERAL else _refuse(
        RefusalReason.HINT_ROLE_DOES_NOT_ASK,
        "A peripheral waiteth to be connected to; it does not initiate a connection.",
    )

    background = _ALLOWED
    if inputs.app_state is AppState.BACKGROUND:
        if inputs.platform is Platform.IOS:
            # ADR-002: iOS background discovery is ASYMMETRIC. A peripheral hint
            # may keep advertising; a central hint may NOT discover peripherals.
            if inputs.hint_role is HintRole.CENTRAL:
                scan = _refuse(
                    RefusalReason.IOS_BACKGROUND_CENTRAL_UNSUPPORTED,
                    "iOS cannot discover peripherals in the background: this device was made "
                    "the central, so it remaineth unavailable until it is opened.",
                )
                background = scan
            else:
                background = _ALLOWED
        else:
            if not inputs.android_foreground_service:
                background = _refuse(
                    RefusalReason.ANDROID_BACKGROUND_NEEDS_FOREGROUND_SERVICE,
                    "Android requires a foreground service of type connectedDevice for "
                    "background radio work; without one the app runneth only in the "
                    "foreground.",
                )
                advertise = _refuse(background.reason, background.detail)
                scan = _refuse(background.reason, background.detail)

    if blocked is not None:
        advertise = blocked
        scan = blocked
        connect = blocked
        background = blocked

    # A LOCKED PROTECTED STORE CARRIETH NO CUSTODY CLAIM: the radio may run, the
    # keychain may not be written.
    keychain_write = _ALLOWED if inputs.protected_data is ProtectedData.AVAILABLE else _refuse(
        RefusalReason.PROTECTED_DATA_UNAVAILABLE,
        "The protected store is locked; no key material may be written while it is.",
    )

    requestable = inputs.authorization in (Authorization.DENIED, Authorization.NOT_DETERMINED)

    return CapabilityState(
        inputs=inputs,
        advertise=advertise,
        scan=scan,
        connect=connect,
        background_discovery=background,
        keychain_write=keychain_write,
        permission_requestable=requestable,
    )


# ---------------------------------------------------------------------------
# The matrix, and the manifest truths it must agree with
# ---------------------------------------------------------------------------

#: The permissions a radio build needeth, per platform, as the MANIFESTS spell them.
REQUIRED_DECLARATIONS = {
    Platform.ANDROID: (
        "android.permission.BLUETOOTH_ADVERTISE",
        "android.permission.BLUETOOTH_SCAN",
        "android.permission.BLUETOOTH_CONNECT",
    ),
    Platform.IOS: (
        "NSBluetoothAlwaysUsageDescription",
    ),
}

#: The background modes a radio build needeth, per platform.
REQUIRED_BACKGROUND_DECLARATIONS = {
    Platform.ANDROID: ("FOREGROUND_SERVICE_CONNECTED_DEVICE",),
    Platform.IOS: ("bluetooth-peripheral",),
}


def describe_matrix() -> str:
    """A human-readable matrix: the four states a user actually meeteth."""
    rows = []
    cases = [
        ("ios/foreground/both", CapabilityInputs(Platform.IOS, hint_role=HintRole.BOTH)),
        ("ios/background/peripheral",
         CapabilityInputs(Platform.IOS, app_state=AppState.BACKGROUND,
                          hint_role=HintRole.PERIPHERAL)),
        ("ios/background/central",
         CapabilityInputs(Platform.IOS, app_state=AppState.BACKGROUND,
                          hint_role=HintRole.CENTRAL)),
        ("android/background/no-service",
         CapabilityInputs(Platform.ANDROID, app_state=AppState.BACKGROUND)),
        ("android/background/service",
         CapabilityInputs(Platform.ANDROID, app_state=AppState.BACKGROUND,
                          android_foreground_service=True)),
        ("light/anything", CapabilityInputs(Platform.ANDROID, profile=Profile.LIGHT)),
        ("force-quit", CapabilityInputs(Platform.IOS, app_state=AppState.FORCE_QUIT)),
    ]
    for name, inputs in cases:
        state = capability_state(inputs)
        rows.append(f"{name:32s} advertise={state.advertise.allowed!s:5s} "
                    f"scan={state.scan.allowed!s:5s} "
                    f"background={state.background_discovery.allowed!s:5s} "
                    f"restore={state.restoration_supported!s:5s}")
    return "\n".join(rows)


if __name__ == "__main__":
    print(describe_matrix())
