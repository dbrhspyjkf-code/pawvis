import Foundation

/// Formats a localized template: the key lives in Localizable.strings with
/// %@ / %.1f placeholders, the arguments fill it in. The bridge for
/// user-facing strings the SwiftUI seam can't reach (controller notices,
/// action-runner feedback, interpolated captions).
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: String(localized: String.LocalizationValue(key)), arguments: args)
}
