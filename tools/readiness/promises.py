#!/usr/bin/env python3
"""The capability-promise ledger (T82).

"Wi-Fi Aware and MultipeerConnectivity are incompatible stubs, while documentation
promises media/tier delivery without a store-compatible design."

So every capability this repository might be READ as promising is listed here with
THREE facts, and one law:

    the ADVERTISED label   what a reader could believe the product does;
    the ENABLING CODE      the profile flag, manifest entry or module that would
                           have to be enabled for that belief to be TRUE;
    the STATUS             ENABLED / DISABLED_EXPLICITLY / UNSUPPORTED_STUB /
                           EXTERNAL_DECISION_OPEN.

THE LAW: A CAPABILITY MAY ONLY BE ADVERTISED IF ITS ENABLING CODE IS ENABLED. A
promise whose code is disabled, a stub, or an open external decision is REFUSED by
name -- because the alternative is a product that claims media delivery it cannot
perform, which is exactly the failure this task existeth to close.

The ledger is not prose: `check(root)` readeth the REAL sources (the Gradle flavour,
the Android manifest, the iOS plist and entitlements, the tier table, the bulk-plane
ADR, the two transport files and the release-gate manifest) and reporteth every
disagreement.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

__all__ = [
    "Status", "Capability", "CAPABILITIES", "Finding", "check", "advertised",
    "refused_promises", "report",
]


class Status:
    ENABLED = "enabled"                          # the code is on: the promise holds
    DISABLED_EXPLICITLY = "disabled_explicitly"  # a flag saith no, on purpose
    UNSUPPORTED_STUB = "unsupported_stub"        # the implementation reports unavailable
    EXTERNAL_DECISION_OPEN = "external_decision_open"   # nobody hath decided yet


@dataclass(frozen=True)
class Capability:
    """One capability, its enabling code, and what may be said about it."""
    id: str
    label: str                    # the words a reader meeteth
    enabling_code: str            # the flag / manifest entry / module that would enable it
    status: str
    advertised_in: tuple = ()     # where the capability is PROMISED AS AVAILABLE
    closed_in: tuple = ()         # where it is DISCUSSED AND CLOSED (the doc must say so)
    note: str = ""
    external_decision: str = ""   # the decision that would have to be made

    @property
    def is_advertised(self) -> bool:
        return bool(self.advertised_in)

    @property
    def may_be_advertised(self) -> bool:
        return self.status == Status.ENABLED


# ---------------------------------------------------------------------------
# THE LEDGER
# ---------------------------------------------------------------------------

CAPABILITIES = (
    Capability(
        id="direct_message",
        label="Send a direct message to a contact",
        enabling_code="LIGHT profile, Archive-only app, no radio permission required",
        status=Status.ENABLED,
        note="the Archive-only product sendeth nothing; the message path is the mesh "
             "runtime's, exercised by its own courts",
    ),
    Capability(
        id="bulk_transfer",
        label="Send large media over a Wi-Fi bulk plane",
        enabling_code="BULK_TRANSFER_ENABLED (the LIGHT flavour declareth false)",
        status=Status.DISABLED_EXPLICITLY,
        closed_in=("docs/adr/ADR-006-bulk-plane.md",),
        note="the ADR is OPEN and both platform transports report unavailable: V4 removed "
             "the false-success paths",
        external_decision="NATIVE_MODELS",
    ),
    Capability(
        id="wifi_aware_transport",
        label="Wi-Fi Aware (NAN) transport",
        enabling_code="android/mesh/.../transport/WifiAwareTransport.kt (an incompatibled stub)",
        status=Status.UNSUPPORTED_STUB,
        note="the transport reporteth unavailable rather than pretending to send",
    ),
    Capability(
        id="multipeer_transport",
        label="MultipeerConnectivity bulk transport",
        enabling_code="ios/Godstone/Sources/GodstoneMesh/BulkTransport.swift",
        status=Status.UNSUPPORTED_STUB,
        note="'Bulk transfer is deliberately unavailable in V4' -- the file's own words",
    ),
    Capability(
        id="group_broadcast_authoring",
        label="Author GROUP and BROADCAST messages",
        enabling_code="MESH_ENABLED (the LIGHT flavour declareth false)",
        status=Status.DISABLED_EXPLICITLY,
        note="only DIRECT and SOS authoring are enabled in this profile",
    ),
    Capability(
        id="sos_broadcast",
        label="Place a distress call",
        enabling_code="SOS_ENABLED (false in the LIGHT flavour; the lab bindeth it)",
        status=Status.DISABLED_EXPLICITLY,
        note="the shipping build carrieth no radio, so no call can leave it",
    ),
    Capability(
        id="medium_tier",
        label="The MEDIUM store product (1.7B model)",
        enabling_code="config/tiers.json MEDIUM.shipping (false)",
        status=Status.DISABLED_EXPLICITLY,
        closed_in=("docs/packaging/TIERS.md",),
        note="a source-level research configuration: buildable archive, NO store-compatible "
             "asset delivery design",
        external_decision="APPROVED_CONTENT",
    ),
    Capability(
        id="large_tier",
        label="The LARGE store product (4B model)",
        enabling_code="config/tiers.json LARGE.shipping (false)",
        status=Status.DISABLED_EXPLICITLY,
        closed_in=("docs/packaging/TIERS.md",),
        note="as MEDIUM: research-only, and Gradle must declare exactly the shipping tiers",
        external_decision="APPROVED_CONTENT",
    ),
    Capability(
        id="oracle_native_model",
        label="On-device Oracle inference with a native model",
        enabling_code="ORACLE_ENABLED (false) and the model-native-stack release gate (BLOCKED)",
        status=Status.EXTERNAL_DECISION_OPEN,
        note="the native stack is not restored: the gate is BLOCKED, not satisfied",
        external_decision="NATIVE_MODELS",
    ),
    Capability(
        id="internet_access",
        label="Internet access",
        enabling_code="android.permission.INTERNET (the shipping manifest REMOVETH it)",
        status=Status.DISABLED_EXPLICITLY,
        note="an offline product: the permission is removed, not merely unused",
    ),
    Capability(
        id="independent_noise_conformance",
        label="Independently conformant Noise vectors",
        enabling_code="crypto/cacophony_vectors.json (no approved external fixture)",
        status=Status.EXTERNAL_DECISION_OPEN,
        note="the A-06 gate is OPEN: the two isles agreeing with each other is not conformance",
        external_decision="A06",
    ),
    Capability(
        id="content_publication",
        label="A reviewed, publishable content corpus",
        enabling_code="the production-corpus release gate (OPEN)",
        status=Status.EXTERNAL_DECISION_OPEN,
        note="no human-reviewed corpus standeth approved",
        external_decision="APPROVED_CONTENT",
    ),
    Capability(
        id="physical_device_support",
        label="Support on physical hardware",
        enabling_code="the device-interoperability, accessibility and battery-thermal gates (BLOCKED)",
        status=Status.EXTERNAL_DECISION_OPEN,
        note="no physical device evidence existeth: the gates are BLOCKED, not satisfied",
        external_decision="HARDWARE",
    ),
)


@dataclass(frozen=True)
class Finding:
    rule: str
    detail: str

    def __str__(self) -> str:
        return "%s: %s" % (self.rule, self.detail)


def advertised() -> tuple:
    """Every capability a reader could meet in words."""
    return tuple(c for c in CAPABILITIES if c.is_advertised)


def refused_promises() -> tuple:
    """THE LAW: an advertised capability whose enabling code is not enabled."""
    return tuple(c for c in CAPABILITIES if c.is_advertised and not c.may_be_advertised)


def _read(root: Path, rel: str) -> str:
    path = root / rel
    return path.read_text(encoding="utf-8", errors="replace") if path.is_file() else ""


def check(root) -> list:
    """Read the REAL sources and report every disagreement with the ledger."""
    root = Path(root)
    findings = []

    gradle = _read(root, "android/app/build.gradle.kts")
    manifest = _read(root, "android/app/src/main/AndroidManifest.xml")
    tiers = _read(root, "config/tiers.json")
    tiers_doc = _read(root, "docs/packaging/TIERS.md")
    adr = _read(root, "docs/adr/ADR-006-bulk-plane.md")
    ios_plist = _read(root, "ios/Godstone/Info.plist")
    entitlements = _read(root, "ios/Godstone/Godstone.entitlements")
    gates = _read(root, "docs/production/RELEASE_GATES_STATUS.json")
    blockers = _read(root, "docs/production-readiness/EXTERNAL_BLOCKERS.json")
    bulk_ios = _read(root, "ios/Godstone/Sources/GodstoneMesh/BulkTransport.swift")
    lab_manifest = _read(root, "android/labmesh/src/main/AndroidManifest.xml")

    # (1) THE LAW: nothing advertised may be disabled, a stub, or an open decision
    for capability in refused_promises():
        findings.append(Finding(
            "advertised-but-not-enabled",
            "%s: advertised in %s while its enabling code (%s) is %s"
            % (capability.id, ", ".join(capability.advertised_in), capability.enabling_code,
               capability.status)))

    # (2) THE PROFILE FLAGS: every capability the ledger calleth DISABLED_EXPLICITLY
    #     and that hangeth on a boolean flag must be false in the shipping flavour
    for flag in ("BULK_TRANSFER_ENABLED", "MESH_ENABLED", "ORACLE_ENABLED", "SOS_ENABLED"):
        expected = 'buildConfigField("boolean", "%s", "false")' % flag
        if expected not in gradle:
            findings.append(Finding(
                "profile-flag-not-disabled",
                "the LIGHT flavour must declare %s false" % flag))

    # (3) NO INTERNET, on either profile's shipping surface: the Archive-only product
    #     is offline, and the LAB carrieth radio but still no INTERNET
    if 'android.permission.INTERNET" tools:node="remove"' not in manifest:
        findings.append(Finding(
            "internet-reachable",
            "the shipping manifest must REMOVE android.permission.INTERNET"))
    if "android.permission.INTERNET" in lab_manifest and 'tools:node="remove"' not in lab_manifest:
        findings.append(Finding(
            "internet-reachable",
            "the lab manifest must not GRANT INTERNET either"))

    # (4) THE TIER TABLE: exactly one shipping tier, and it is LIGHT
    shipping_true = tiers.count('"shipping": true')
    if shipping_true != 1:
        findings.append(Finding(
            "tier-table-drift",
            "config/tiers.json must mark EXACTLY one shipping tier; it marketh %d"
            % shipping_true))
    if '"LIGHT"' not in tiers or '"shipping": true' not in tiers:
        findings.append(Finding("tier-table-drift", "the shipping tier must be LIGHT"))
    for tier in ("MEDIUM", "LARGE"):
        block = tiers.split('"%s"' % tier, 1)
        if len(block) > 1 and '"shipping": false' not in block[1][:240]:
            findings.append(Finding(
                "tier-promise", "%s must be marked research-only (shipping: false)" % tier))

    # (5) THE DOCS MUST SAY SO: a research-only tier must be DOCUMENTED as research
    for word in ("research", "MEDIUM", "LARGE", "shipping"):
        if word.lower() not in tiers_doc.lower():
            findings.append(Finding("tier-doc-silent", "TIERS.md must mention %r" % word))

    # (6) THE BULK PLANE: the ADR must be OPEN and the stub must SAY it is unavailable
    if "OPEN" not in adr:
        findings.append(Finding("bulk-adr-status", "ADR-006 must state its status"))
    if "unavailable" not in bulk_ios.lower():
        findings.append(Finding(
            "bulk-stub-silent",
            "BulkTransport.swift must report unavailable rather than pretending to send"))

    # (7) THE iOS SHIPPING SURFACE: no bulk/multipeer capability declared
    for forbidden in ("NSLocalNetworkUsageDescription", "NSBonjourServices",
                      "UIBackgroundModes"):
        if forbidden in ios_plist:
            findings.append(Finding(
                "ios-capability-advertised",
                "the shipping Info.plist must not declare %s" % forbidden))
    for forbidden in ("multipeer", "Multipeer", "wifi-aware", "Wi-Fi Aware"):
        if forbidden in entitlements:
            findings.append(Finding(
                "ios-entitlement-advertised",
                "the shipping entitlements must not grant %s" % forbidden))

    # (8) EVERY OPEN DECISION MUST BE NAMED IN THE RELEASE MANIFEST, and none may be
    #     CLOSED by this task: the ledger's EXTERNAL_DECISION_OPEN capabilities must
    #     map to a gate that is OPEN or BLOCKED
    for capability in CAPABILITIES:
        if capability.status != Status.EXTERNAL_DECISION_OPEN:
            continue
        if not capability.external_decision:
            findings.append(Finding(
                "open-decision-unnamed",
                "%s is externally open but nameth no decision" % capability.id))
            continue
        token = capability.external_decision.upper()
        if token not in gates.upper() and token not in blockers.upper():
            findings.append(Finding(
                "open-decision-unrecorded",
                "%s nameth %r, which NEITHER the release manifest nor the external-blocker "
                "register carrieth" % (capability.id, capability.external_decision)))

    # (9) A CLOSED CAPABILITY MUST BE CLOSED **IN WORDS**: the document that
    #     discusseth it must state the closure, or a reader would take the mention
    #     for a promise
    closed_words = {
        "docs/adr/ADR-006-bulk-plane.md": ("OPEN", "unavailable"),
        "docs/packaging/TIERS.md": ("research", "shipping"),
    }
    for capability in CAPABILITIES:
        for rel in capability.closed_in:
            text = _read(root, rel)
            if not text:
                findings.append(Finding("closure-doc-missing", "%s: %s absent" % (capability.id, rel)))
                continue
            required = closed_words.get(rel, ("shipping",))
            for word in required:
                if word.lower() not in text.lower():
                    findings.append(Finding(
                        "closure-unstated",
                        "%s is discussed in %s, which doth not state the closure (%r)"
                        % (capability.id, rel, word)))

    # (10) NO ADVERTISED CAPABILITY MAY BE A STUB: a stub is the loudest promise and
    #     the emptiest one
    for capability in CAPABILITIES:
        if capability.status == Status.UNSUPPORTED_STUB and capability.is_advertised:
            findings.append(Finding(
                "stub-advertised",
                "%s is an UNSUPPORTED STUB and is advertised in %s"
                % (capability.id, ", ".join(capability.advertised_in))))

    return findings


def report(root) -> str:
    findings = check(root)
    lines = ["capability promises: %d capabilities, %d advertised, %d refused"
             % (len(CAPABILITIES), len(advertised()), len(refused_promises()))]
    for capability in CAPABILITIES:
        lines.append("  %-28s %-22s advertised_in=%d"
                     % (capability.id, capability.status, len(capability.advertised_in)))
    for finding in findings:
        lines.append("  FINDING " + str(finding))
    lines.append("VERDICT: " + ("PASS" if not findings else "FAIL (%d)" % len(findings)))
    return "\n".join(lines)


if __name__ == "__main__":
    import sys
    here = Path(__file__).resolve().parents[2] if len(Path(__file__).resolve().parents) > 2 else Path(".")
    print(report(here))
    raise SystemExit(1 if check(here) else 0)
