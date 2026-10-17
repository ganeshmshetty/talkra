// BrandColor.swift
// OpenClip
//
// Talkra's indigo, the midpoint of the app icon's gradient (#7C5CFF → #2E31DE); see
// `scripts/generate_icons.py`.

import SwiftUI

public extension Color {
    /// The brand indigo. In the settings sidebar it is reserved for rows Talkra ships, so a
    /// third-party extension's generated tint can never claim it — see `SettingsTint`.
    static let talkraBrand = Color(red: 0x55 / 255, green: 0x47 / 255, blue: 0xEE / 255)
}
