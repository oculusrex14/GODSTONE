import SwiftUI

/// Constraint C7: usable under stress, at night, with shaking hands.
///
///  * Dark by default. A white screen at night destroys night vision and is a
///    visible beacon to anyone looking for you.
///  * Night mode is pure red on black: red light preserves scotopic vision.
///  * Minimum tap target 56pt, well above Apple's 44pt, because the user may be
///    cold, injured, or wearing gloves.
enum GodstoneTheme {

    static let stone   = Color(red: 0.07, green: 0.08, blue: 0.09)
    static let ember   = Color(red: 0.90, green: 0.45, blue: 0.13)
    static let signal  = Color(red: 0.20, green: 0.78, blue: 0.55)
    static let warning = Color(red: 0.96, green: 0.76, blue: 0.20)
    static let danger  = Color(red: 0.86, green: 0.21, blue: 0.21)

    static let nightRed        = Color(red: 0.80, green: 0.00, blue: 0.00)
    static let nightBackground = Color.black

    static let minimumTapTarget: CGFloat = 56
    static let bodyTextSize: CGFloat = 18
}

/// Applied globally when the user enables Night Mode.
struct NightModeModifier: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .foregroundStyle(GodstoneTheme.nightRed)
                .tint(GodstoneTheme.nightRed)
                .background(GodstoneTheme.nightBackground)
                .environment(\.colorScheme, .dark)
        } else {
            content
        }
    }
}

extension View {
    func nightMode(_ enabled: Bool) -> some View {
        modifier(NightModeModifier(enabled: enabled))
    }
}
