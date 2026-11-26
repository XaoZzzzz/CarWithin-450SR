// SPDX-License-Identifier: AGPL-3.0-or-later
// License: FILE: AGPL-3.0-or-later (see NOTICE.md)
//
// Extracted from OpenCfMotoKit `Settings/SettingsTypes.swift` (only this type is
// needed by BikeProfile + EasyConnLink in the ported closure).

/// Per-edge insets in dash pixels (0…200). `customised == false` → the profile default applies
/// (800NK Advanced: top 22, all others 0).
public struct ScreenMargins: Sendable, Equatable, Codable {
    public var customised: Bool
    public var top: Int
    public var bottom: Int
    public var left: Int
    public var right: Int
    public init(customised: Bool = false, top: Int = 0, bottom: Int = 0, left: Int = 0, right: Int = 0) {
        self.customised = customised; self.top = top; self.bottom = bottom; self.left = left; self.right = right
    }
    public static let zero = ScreenMargins()
    public func clamped() -> ScreenMargins {
        func c(_ v: Int) -> Int { min(200, max(0, v)) }
        return ScreenMargins(customised: customised, top: c(top), bottom: c(bottom), left: c(left), right: c(right))
    }
}
