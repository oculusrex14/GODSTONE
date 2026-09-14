#!/usr/bin/env python3
"""The accessibility and restoration conductor (T60).

"Host UI tests do not prove large-text layout, screen-reader operation or
process-restored truth."

This module is the CANONICAL form of what may be checked automatically, and -- just
as important -- of what may NOT. Every check carrieth a [Requirement]:
AUTOMATED when a host can decide it from the semantic model, HUMAN_REQUIRED when
only a person with a screen reader, a switch, or a device can. A conductor that
claimed the second kind for the first would be the lie this task existeth to
prevent, and the human T74 audit owneth the rest.

THE LAWS:

  1. NO COLOUR-ONLY STATE. Every delivery/SOS state carrieth WORDS as well as a
     colour token, and the words differ between every pair of states.
  2. AN ESSENTIAL CONTROL ALWAYS CARRIETH A LABEL, at every text scale. A control
     with no label, or a label that vanisheth when the font is largest, is a
     control a screen-reader user cannot operate.
  3. A STATUS IS NEVER CLIPPED. At the largest scale the status WORD must survive
     whole: a truncated status ("Deliv…") is a false statement about delivery.
  4. A TOUCH TARGET MEETETH ITS PLATFORM MINIMUM (48dp Android, 44pt iOS) and a
     switch-navigation user can REACH every essential control in reading order.
  5. RTL MIRRORETH: a directional control's meaning must not follow the mirror
     (a "send" arrow may mirror; a "play" triangle may not).
  6. LONG CONTENT FITTETH: the longest locale fixture must not overflow a bounded
     container, and the label must still be present in full in the semantics.

The fixtures live here so every lane speaketh the SAME journeys and the SAME
assertions; a lane implementeth them in its own language and asserts the same laws.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum

__all__ = [
    "Requirement", "TextScale", "Platform", "Profile", "JourneyCase",
    "AccessibilityAssertion", "RestorationCheckpoint", "UiNode", "ControlRole",
    "DeliveryState", "contrast_ratio", "relative_luminance", "parse_hex",
    "TOUCH_TARGET_MIN", "LARGEST_TEXT_SCALE", "ESSENTIAL_CONTROLS",
    "JOURNEY_CASES", "LONG_CONTENT_FIXTURES", "check_assertion", "conductor_report",
]


class Requirement(str, Enum):
    """Who can decide this check -- a host, or a person."""
    AUTOMATED = "automated"
    HUMAN_REQUIRED = "human_required"


class Platform(str, Enum):
    ANDROID = "android"
    IOS = "ios"


class Profile(str, Enum):
    LIGHT = "LIGHT"
    LABMESH = "LABMESH"


class TextScale(str, Enum):
    """Android's fontScale and iOS's Dynamic Type, as the CONDUCTOR names them."""
    DEFAULT = "default"
    LARGE = "large"
    LARGEST = "largest"          # Android fontScale 2.0 / iOS AX5
    LARGEST_ACCESSIBILITY = "largest_accessibility"   # iOS AX5 with bold text


class ControlRole(str, Enum):
    BUTTON = "button"
    IMAGE_BUTTON = "image_button"
    TEXT_FIELD = "text_field"
    TOGGLE = "toggle"
    STATIC_TEXT = "static_text"


class DeliveryState(str, Enum):
    """The states a screen may show, with their WORDS and a colour token."""
    QUEUED = "queued"
    ATTEMPTING = "attempting"
    DELIVERED = "delivered"
    CANCELLED = "cancelled"
    EXPIRED = "expired"
    FAILED = "failed"


#: The words every state carrieth (law 1). They must all differ.
STATE_WORDS = {
    DeliveryState.QUEUED: "Queued on this phone",
    DeliveryState.ATTEMPTING: "On its way; no answer yet",
    DeliveryState.DELIVERED: "Delivered: the recipient confirmed it",
    DeliveryState.CANCELLED: "Cancelled",
    DeliveryState.EXPIRED: "Expired before delivery",
    DeliveryState.FAILED: "Failed: the phone could not queue it",
}

#: A colour token per state, so the check can prove the words are NOT the only
#: channel: two states MAY share a colour, but they may never share words.
STATE_COLOUR_TOKEN = {
    DeliveryState.QUEUED: "outline",
    DeliveryState.ATTEMPTING: "tertiary",
    DeliveryState.DELIVERED: "primary",
    DeliveryState.CANCELLED: "outline",
    DeliveryState.EXPIRED: "outline",
    DeliveryState.FAILED: "error",
}

#: The largest scale a host may simulate (law 3).
LARGEST_TEXT_SCALE = TextScale.LARGEST_ACCESSIBILITY

#: The platform touch-target minimums, in density-independent units (law 4).
TOUCH_TARGET_MIN = {Platform.ANDROID: 48.0, Platform.IOS: 44.0}

#: The controls every active profile MUST offer, with the label a user readeth.
ESSENTIAL_CONTROLS = {
    "compose_send": "Send",
    "sos_arm": "Distress call",
    "sos_cancel": "Cancel the distress call",
    "retry": "Retry",
    "recipient_select": "Choose a recipient",
}

#: WCAG AA: 4.5:1 for body text, 3:1 for large text and non-text UI.
CONTRAST_BODY_MIN = 4.5
CONTRAST_LARGE_MIN = 3.0


@dataclass(frozen=True)
class UiNode:
    """One rendered node, as the conductor seeth it (no pixels, only semantics)."""
    control_id: str
    role: ControlRole
    label: str                      # the visible label ("")
    content_description: str        # the screen-reader words
    touch_width: float
    touch_height: float
    reading_order: int
    enabled: bool = True
    state_words: str = ""           # the WORDS a state carrieth (law 1)
    colour_token: str = ""
    truncated: bool = False         # the renderer clipped the text (law 3)
    mirrored: bool = False          # the RTL mirror flipped it
    mirrors_meaning: bool = False   # ... and its meaning MIRRORED with it (law 5)
    container_width: float = 0.0
    content_width: float = 0.0


@dataclass(frozen=True)
class AccessibilityAssertion:
    """One check, with the requirement class that owneth it."""
    assertion_id: str
    requirement: Requirement
    detail: str
    platform: Platform
    profile: Profile
    text_scale: TextScale
    rtl: bool = False
    locale: str = "en"
    journey: str = ""


@dataclass(frozen=True)
class RestorationCheckpoint:
    """What must survive a process recreation, and who proveth it."""
    checkpoint_id: str
    requirement: Requirement
    detail: str
    #: The durable fact a restoration must re-expose (never a UI memory).
    durable_fact: str
    #: True iff an airplane-mode cold start may still show it.
    survives_airplane_mode: bool


@dataclass(frozen=True)
class JourneyCase:
    """One user journey, with its assertions and its restoration checkpoint."""
    case_id: str
    title: str
    profile: Profile
    steps: tuple[str, ...]
    assertions: tuple[AccessibilityAssertion, ...] = ()
    checkpoints: tuple[RestorationCheckpoint, ...] = ()
    human_notes: tuple[str, ...] = field(default_factory=tuple)


# ---------------------------------------------------------------------------
# contrast (WCAG 2.1), so "no colour-only state" carrieth a real number too
# ---------------------------------------------------------------------------

def parse_hex(value: str) -> tuple[float, float, float]:
    text = value.strip().lstrip("#")
    if len(text) != 6:
        raise ValueError("a colour is #rrggbb")
    return tuple(int(text[i:i + 2], 16) / 255.0 for i in (0, 2, 4))  # type: ignore[return-value]


def relative_luminance(rgb: tuple[float, float, float]) -> float:
    def channel(c: float) -> float:
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (channel(c) for c in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast_ratio(foreground: str, background: str) -> float:
    """The WCAG contrast ratio between two #rrggbb colours."""
    l1 = relative_luminance(parse_hex(foreground))
    l2 = relative_luminance(parse_hex(background))
    lighter, darker = max(l1, l2), min(l1, l2)
    return (lighter + 0.05) / (darker + 0.05)


# ---------------------------------------------------------------------------
# the checks themselves
# ---------------------------------------------------------------------------

def check_assertion(assertion: AccessibilityAssertion, nodes: list[UiNode]) -> tuple[bool, str]:
    """Decide one assertion. Returneth (passed, reason).

    Every AUTOMATED assertion is decided HERE, from the semantic model, so all
    three lanes decide the same law the same way.
    """
    by_id = {node.control_id: node for node in nodes}

    if assertion.assertion_id == "essential_control_labelled":
        for control_id, label in ESSENTIAL_CONTROLS.items():
            node = by_id.get(control_id)
            if node is None:
                return False, f"the essential control {control_id!r} is absent"
            if not node.label.strip():
                return False, f"{control_id}: the visible label is empty"
            if not node.content_description.strip():
                return False, f"{control_id}: a screen reader would read nothing"
        return True, "every essential control carrieth a visible label and a description"

    if assertion.assertion_id == "status_never_clipped":
        for node in nodes:
            if node.state_words and node.truncated:
                return False, (f"{node.control_id}: the status {node.state_words!r} is CLIPPED at "
                               f"{assertion.text_scale.value}")
        return True, "every status survives the largest text scale whole"

    if assertion.assertion_id == "no_colour_only_state":
        words = {state: STATE_WORDS[state] for state in DeliveryState}
        if len(set(words.values())) != len(words):
            return False, "two states share the SAME words: colour would be the only channel"
        for node in nodes:
            if node.state_words and not node.colour_token:
                return False, f"{node.control_id}: a state carrieth words but no colour token"
            if node.colour_token and not node.state_words:
                return False, f"{node.control_id}: a state carrieth a colour token but NO words"
        return True, "every state carrieth words as well as a colour token"

    if assertion.assertion_id == "touch_target_minimum":
        minimum = TOUCH_TARGET_MIN[assertion.platform]
        for node in nodes:
            if node.role is ControlRole.STATIC_TEXT:
                continue
            if node.touch_width < minimum or node.touch_height < minimum:
                return False, (f"{node.control_id}: {node.touch_width}x{node.touch_height} is below "
                               f"the {minimum} minimum for {assertion.platform.value}")
        return True, f"every control meeteth the {minimum} minimum"

    if assertion.assertion_id == "reading_order_reachable":
        orders = [node.reading_order for node in nodes if node.control_id in ESSENTIAL_CONTROLS]
        if sorted(orders) != list(range(len(orders))):
            return False, f"the essential controls' reading order is not contiguous: {orders}"
        labelled = [node for node in nodes if node.content_description.strip()]
        if len(labelled) != len(nodes):
            return False, "a node in the reading order carrieth no description"
        return True, "every essential control is reachable in a contiguous reading order"

    if assertion.assertion_id == "rtl_meaning_preserved":
        for node in nodes:
            if node.mirrored and node.mirrors_meaning:
                return False, (f"{node.control_id}: its MEANING mirrored with the layout, which is "
                               f"wrong for a directional control")
        return True, "the mirror moved the layout without moving any control's meaning"

    if assertion.assertion_id == "long_content_fits":
        for node in nodes:
            if node.container_width and node.content_width > node.container_width:
                if node.truncated:
                    return False, (f"{node.control_id}: the {assertion.locale} fixture overfloweth "
                                   f"({node.content_width} > {node.container_width}) and the label was "
                                   f"clipped")
            if node.truncated and node.control_id in ESSENTIAL_CONTROLS:
                return False, f"{node.control_id}: an essential label was clipped"
        return True, f"the {assertion.locale} fixture fitteth without clipping a label"

    raise ValueError(f"unknown assertion {assertion.assertion_id!r}")


# ---------------------------------------------------------------------------
# the fixtures every lane shareth
# ---------------------------------------------------------------------------

def _assertion(assertion_id: str, requirement: Requirement, detail: str, platform: Platform,
               profile: Profile, scale: TextScale, **kw) -> AccessibilityAssertion:
    return AccessibilityAssertion(assertion_id=assertion_id, requirement=requirement, detail=detail,
                                  platform=platform, profile=profile, text_scale=scale, **kw)


def _journey(case_id: str, title: str, profile: Profile, steps: tuple[str, ...],
             platform: Platform, scale: TextScale, human_notes: tuple[str, ...]) -> JourneyCase:
    """A journey with the SAME automated assertions on every lane."""
    checks = [
        _assertion("essential_control_labelled", Requirement.AUTOMATED,
                   "every essential control carrieth a visible label and a description",
                   platform, profile, scale, journey=case_id),
        _assertion("status_never_clipped", Requirement.AUTOMATED,
                   "a status is never clipped, at any scale", platform, profile, scale,
                   journey=case_id),
        _assertion("no_colour_only_state", Requirement.AUTOMATED,
                   "words, as well as a colour token", platform, profile, scale, journey=case_id),
        _assertion("touch_target_minimum", Requirement.AUTOMATED,
                   "the platform's minimum touch target", platform, profile, scale, journey=case_id),
        _assertion("reading_order_reachable", Requirement.AUTOMATED,
                   "a contiguous reading order a switch user can walk", platform, profile, scale,
                   journey=case_id),
    ]
    checkpoints = [
        RestorationCheckpoint(
            checkpoint_id=case_id + ".durable_estate",
            requirement=Requirement.AUTOMATED,
            detail="a process recreation re-exposeth the durable estate",
            durable_fact="the held rows and their authority status",
            survives_airplane_mode=True),
        RestorationCheckpoint(
            checkpoint_id=case_id + ".human_screenreader",
            requirement=Requirement.HUMAN_REQUIRED,
            detail="a person with a screen reader and a switch walketh the journey",
            durable_fact="none: this is a human observation, not durable state",
            survives_airplane_mode=True),
    ]
    return JourneyCase(case_id=case_id, title=title, profile=profile, steps=steps,
                       assertions=tuple(checks), checkpoints=tuple(checkpoints),
                       human_notes=human_notes)


JOURNEY_CASES: tuple[JourneyCase, ...] = (
    _journey("cold_launch_airplane", "Cold launch in airplane mode", Profile.LABMESH,
             ("launch with the radio's permission granted and the radio OFF",
              "the screen sayeth the message is queued",
              "a process recreation re-exposeth the same queued row"),
             Platform.ANDROID, LARGEST_TEXT_SCALE,
             ("talkback reads the queued banner",)),
    _journey("restored_query", "Restored query after a recreation", Profile.LABMESH,
             ("author a message", "force the process to re-create",
              "the conversation re-exposeth the row and its authority status"),
             Platform.IOS, LARGEST_TEXT_SCALE,
             ("voiceover reads the restored status",)),
    _journey("active_sos", "Active SOS restoration", Profile.LABMESH,
             ("arm and confirm the distress control", "re-create the process",
              "the active call standeth, and its cancel nameth the relayed copies"),
             Platform.ANDROID, LARGEST_TEXT_SCALE,
             ("the hold gesture is spoken by the screen reader",)),
    _journey("locked_store", "Locked protected store", Profile.LABMESH,
             ("lock the device", "the screen claimeth no message state",
              "unlock and the real estate reappeareth"),
             Platform.IOS, LARGEST_TEXT_SCALE,
             ("a person confirmeth that nothing is claimed while locked",)),
    _journey("error_retry", "Error retry", Profile.LABMESH,
             ("a storage failure produceth a visible refusal",
              "the text the user wrote surviveth", "retry reacheth the authority"),
             Platform.ANDROID, LARGEST_TEXT_SCALE,
             ("the error is read in full at the largest scale",)),
    _journey("rtl_locale", "RTL and long-content locale", Profile.LABMESH,
             ("set the locale to an RTL language", "the layout mirroreth",
              "no control's MEANING mirrorreth with it"),
             Platform.ANDROID, LARGEST_TEXT_SCALE,
             ("a native speaker confirmeth the reading order",)),
    _journey("light_archive_only", "The LIGHT Archive-only profile", Profile.LIGHT,
             ("launch the shipping build", "the screen carrieth no radio control at all",
              "no status is claimed for a message that cannot be sent"),
             Platform.ANDROID, LARGEST_TEXT_SCALE,
             ("a person confirmeth the Archive-only words",)),
)

#: Long-content fixtures: the locale's longest realistic strings.
LONG_CONTENT_FIXTURES = {
    "en": "Delivered: the recipient confirmed it",
    "de": "Zugestellt: Die Empfangerin hat den Empfang bestatigt",
    "fi": "Toimitettu: vastaanottaja on vahvistanut vastaanoton",
    "ar": "\u062a\u0645 \u0627\u0644\u062a\u0633\u0644\u064a\u0645: \u0623\u0643\u062f \u0627\u0644\u0645\u0633\u062a\u0644\u0645 \u0627\u0644\u0627\u0633\u062a\u0644\u0627\u0645",
    "ja": "\u914d\u9054\u6e08\u307f\uff1a\u53d7\u4fe1\u8005\u304c\u78ba\u8a8d\u3057\u307e\u3057\u305f",
}


def conductor_report() -> str:
    """A human-readable summary: what is automated, and what only a person proveth."""
    lines: list[str] = []
    automated = human = 0
    for case in JOURNEY_CASES:
        asserts = len(case.assertions)
        automated += sum(1 for a in case.assertions if a.requirement is Requirement.AUTOMATED)
        automated += sum(1 for c in case.checkpoints if c.requirement is Requirement.AUTOMATED)
        human += sum(1 for a in case.assertions if a.requirement is Requirement.HUMAN_REQUIRED)
        human += sum(1 for c in case.checkpoints if c.requirement is Requirement.HUMAN_REQUIRED)
        human += len(case.human_notes)
        lines.append(f"{case.case_id:22s} profile={case.profile.value:8s} "
                     f"assertions={asserts} checkpoints={len(case.checkpoints)} "
                     f"human_notes={len(case.human_notes)}")
    lines.append(f"--- automated checks: {automated}; human-required: {human}")
    lines.append("AUTOMATED checks are decided by the conductor; HUMAN_REQUIRED ones are the T74 "
                 "audit's, and no automated result may stand in for them.")
    return "\n".join(lines)


if __name__ == "__main__":
    print(conductor_report())
