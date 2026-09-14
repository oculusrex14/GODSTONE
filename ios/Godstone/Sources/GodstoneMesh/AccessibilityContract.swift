import Foundation

// ---------------------------------------------------------------------------
// T60 -- the accessibility contract for the iOS isle.
//
// The twin of android/mesh/src/main/java/io/godstone/mesh/a11y/
// AccessibilityContract.kt: the SAME laws, the SAME words, and the platform's own
// numbers (44pt here, 48dp there). "Host UI tests do not prove large-text layout,
// screen-reader operation or process-restored truth" -- so this contract decideth
// only what a HOST can decide, and sayeth which checks belong to a person (the T74
// human audit).
// ---------------------------------------------------------------------------

/// Who can decide a check.
public enum Requirement: String, Sendable, Equatable {
    case automated
    case humanRequired = "human_required"
}

/// The largest scale a host may simulate (iOS AX5, the largest accessibility size).
public enum TextScale: String, Sendable, Equatable, CaseIterable {
    case defaultSize = "default"
    case large = "large"
    case largest = "largest"
    case largestAccessibility = "largest_accessibility"

    public var isLargest: Bool { self == .largestAccessibility }

    /// iOS's own name for the largest Dynamic Type size a host may set.
    public static let uICTContentSizeCategory = "UICTContentSizeCategoryAccessibilityXXXL"
}

/// The platform, for the numbers that differ.
public enum A11yPlatform: String, Sendable, Equatable {
    case android
    case ios

    public var touchTargetMinDp: Double {
        switch self {
        case .android: return 48
        case .ios: return 44
        }
    }
}

public enum ControlRole: String, Sendable, Equatable {
    case button
    case imageButton = "image_button"
    case textField = "text_field"
    case toggle
    case staticText = "static_text"
}

/// One rendered node, as the contract seeth it: semantics only, no pixels.
public struct UiNode: Sendable, Equatable {
    public let controlId: String
    public let role: ControlRole
    public let label: String
    public let contentDescription: String
    public let touchWidthDp: Double
    public let touchHeightDp: Double
    public let readingOrder: Int
    public var enabled: Bool = true
    public var stateWords: String = ""
    public var colourToken: String = ""
    public var truncated: Bool = false
    public var mirrored: Bool = false
    public var mirrorsMeaning: Bool = false
    public var containerWidthDp: Double = 0
    public var contentWidthDp: Double = 0

    public init(controlId: String, role: ControlRole, label: String,
                contentDescription: String, touchWidthDp: Double, touchHeightDp: Double,
                readingOrder: Int, enabled: Bool = true, stateWords: String = "",
                colourToken: String = "", truncated: Bool = false, mirrored: Bool = false,
                mirrorsMeaning: Bool = false, containerWidthDp: Double = 0,
                contentWidthDp: Double = 0) {
        self.controlId = controlId; self.role = role; self.label = label
        self.contentDescription = contentDescription
        self.touchWidthDp = touchWidthDp; self.touchHeightDp = touchHeightDp
        self.readingOrder = readingOrder; self.enabled = enabled
        self.stateWords = stateWords; self.colourToken = colourToken
        self.truncated = truncated; self.mirrored = mirrored
        self.mirrorsMeaning = mirrorsMeaning
        self.containerWidthDp = containerWidthDp; self.contentWidthDp = contentWidthDp
    }
}

/// One check, with the class of requirement that owneth it.
public struct AccessibilityAssertion: Sendable, Equatable {
    public let assertionId: String
    public let requirement: Requirement
    public let platform: A11yPlatform
    public let textScale: TextScale
    public let rtl: Bool
    public let locale: String
    public let journey: String

    public init(assertionId: String, requirement: Requirement, platform: A11yPlatform,
                textScale: TextScale, rtl: Bool = false, locale: String = "en",
                journey: String = "") {
        self.assertionId = assertionId; self.requirement = requirement
        self.platform = platform; self.textScale = textScale
        self.rtl = rtl; self.locale = locale; self.journey = journey
    }
}

/// What must survive a process recreation, and who proveth it.
public struct RestorationCheckpoint: Sendable, Equatable {
    public let checkpointId: String
    public let requirement: Requirement
    public let durableFact: String
    public let survivesAirplaneMode: Bool

    public init(checkpointId: String, requirement: Requirement, durableFact: String,
                survivesAirplaneMode: Bool) {
        self.checkpointId = checkpointId; self.requirement = requirement
        self.durableFact = durableFact; self.survivesAirplaneMode = survivesAirplaneMode
    }
}

/// A check's verdict: never a bare Boolean, always a reason.
public struct Verdict: Sendable, Equatable {
    public let passed: Bool
    public let reason: String

    public static func pass(_ reason: String) -> Verdict { Verdict(passed: true, reason: reason) }
    public static func fail(_ reason: String) -> Verdict { Verdict(passed: false, reason: reason) }
}

public enum AccessibilityContract {
    public static let largestScaleName = "largest_accessibility"

    /// The controls every profile MUST offer, with the label a user readeth.
    public static let essentialControls: [(String, String)] = [
        ("recipient_select", "Choose a recipient"),
        ("compose_send", "Send"),
        ("sos_arm", "Distress call"),
        ("sos_cancel", "Cancel the distress call"),
        ("retry", "Retry"),
    ]

    /// The WORDS the delivery vocabulary carrieth -- the SAME words the durable
    /// projection speaketh (T43), so no screen inventeth a status, and no two read
    /// alike, which is what maketh colour a SECOND channel.
    public static let stateWords: [(String, String)] = [
        ("QUEUED", "Queued on this phone"),
        ("ATTEMPTING", "On its way; no answer yet"),
        ("DELIVERED", "Delivered: the recipient confirmed it"),
        ("CANCELLED", "Cancelled"),
        ("EXPIRED", "Expired before delivery"),
        ("FAILED", "Failed: the phone could not queue it"),
    ]

    public static let stateColourToken: [(String, String)] = [
        ("QUEUED", "outline"), ("ATTEMPTING", "tertiary"), ("DELIVERED", "primary"),
        ("CANCELLED", "outline"), ("EXPIRED", "outline"), ("FAILED", "error"),
    ]

    public static let contrastBodyMin = 4.5
    public static let contrastLargeMin = 3.0

    /// The VoiceOver words for the hold-to-confirm control.
    public static let sosIdleHint = "Hold to place a distress call. It takes two steps."
    public static let sosArmedHint = "Armed. Confirm to place the call, or dismiss to cancel."
    public static let sosCancelLabel = "Cancel the distress call"
    public static let sosConfirmLabel = "Confirm and place the distress call"

    // ---- the checks ------------------------------------------------------

    public static func checkEssentialControlsLabelled(_ nodes: [UiNode]) -> Verdict {
        let byId = Dictionary(uniqueKeysWithValues: nodes.map { ($0.controlId, $0) })
        for (controlId, _) in essentialControls {
            guard let node = byId[controlId] else {
                return .fail("the essential control '\(controlId)' is absent")
            }
            if node.label.trimmingCharacters(in: .whitespaces).isEmpty {
                return .fail("\(controlId): the visible label is empty")
            }
            if node.contentDescription.trimmingCharacters(in: .whitespaces).isEmpty {
                return .fail("\(controlId): a screen reader would read nothing")
            }
        }
        return .pass("every essential control carrieth a visible label and a description")
    }

    public static func checkStatusNeverClipped(_ nodes: [UiNode], _ scale: TextScale) -> Verdict {
        for node in nodes where !node.stateWords.isEmpty && node.truncated {
            return .fail("\(node.controlId): the status '\(node.stateWords)' is CLIPPED at "
                         + scale.rawValue)
        }
        return .pass("every status survives the largest text scale whole")
    }

    public static func checkNoColourOnlyState(_ nodes: [UiNode]) -> Verdict {
        let words = Set(stateWords.map { $0.1 })
        if words.count != stateWords.count {
            return .fail("two states share the SAME words")
        }
        for node in nodes {
            if node.stateWords.isEmpty && node.colourToken.isEmpty { continue }
            if !node.stateWords.isEmpty && node.colourToken.isEmpty {
                return .fail("\(node.controlId): a state carrieth words but no colour token")
            }
            if !node.colourToken.isEmpty && node.stateWords.isEmpty {
                return .fail("\(node.controlId): a state carrieth a colour but NO words")
            }
        }
        return .pass("every state carrieth words as well as a colour token")
    }

    public static func checkTouchTargets(_ nodes: [UiNode], _ platform: A11yPlatform) -> Verdict {
        for node in nodes where node.role != .staticText {
            if node.touchWidthDp < platform.touchTargetMinDp
                || node.touchHeightDp < platform.touchTargetMinDp {
                return .fail("\(node.controlId): \(node.touchWidthDp)x\(node.touchHeightDp) is "
                             + "below the \(platform.touchTargetMinDp) minimum for "
                             + platform.rawValue)
            }
        }
        return .pass("every control meeteth the \(platform.touchTargetMinDp) minimum")
    }

    public static func checkReadingOrder(_ nodes: [UiNode]) -> Verdict {
        let essentialIds = Set(essentialControls.map { $0.0 })
        let orders = nodes.filter { essentialIds.contains($0.controlId) }
            .map { $0.readingOrder }.sorted()
        if orders != Array(0..<orders.count) {
            return .fail("the essential controls' reading order is not contiguous: \(orders)")
        }
        if nodes.contains(where: { $0.contentDescription.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return .fail("a node in the reading order carrieth no description")
        }
        return .pass("every essential control is reachable in a contiguous reading order")
    }

    public static func checkRtlMeaning(_ nodes: [UiNode], rtl: Bool) -> Verdict {
        for node in nodes where node.mirrored && node.mirrorsMeaning {
            return .fail("\(node.controlId): its MEANING mirrored with the layout (rtl=\(rtl))")
        }
        return .pass("the mirror may move the layout, never a control's meaning")
    }

    public static func checkLongContent(_ nodes: [UiNode], locale: String) -> Verdict {
        let essentialIds = Set(essentialControls.map { $0.0 })
        for node in nodes {
            if node.containerWidthDp > 0 && node.contentWidthDp > node.containerWidthDp
                && node.truncated {
                return .fail("\(node.controlId): the \(locale) fixture overfloweth "
                             + "(\(node.contentWidthDp) > \(node.containerWidthDp)) and was clipped")
            }
            if node.truncated && essentialIds.contains(node.controlId) {
                return .fail("\(node.controlId): an essential label was clipped")
            }
        }
        return .pass("the \(locale) fixture fitteth without clipping a label")
    }

    // ---- contrast (WCAG 2.1) --------------------------------------------

    public static func contrastRatio(_ foregroundHex: String, _ backgroundHex: String) throws -> Double {
        let l1 = relativeLuminance(try parseHex(foregroundHex))
        let l2 = relativeLuminance(try parseHex(backgroundHex))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    struct ColourError: Error { let reason: String }

    static func parseHex(_ value: String) throws -> (Double, Double, Double) {
        let text = value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard text.count == 6, let value = Int(text, radix: 16) else {
            throw ColourError(reason: "a colour is #rrggbb")
        }
        return (Double((value >> 16) & 0xFF) / 255.0,
                Double((value >> 8) & 0xFF) / 255.0,
                Double(value & 0xFF) / 255.0)
    }

    static func relativeLuminance(_ rgb: (Double, Double, Double)) -> Double {
        func channel(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(rgb.0) + 0.7152 * channel(rgb.1) + 0.0722 * channel(rgb.2)
    }
}
