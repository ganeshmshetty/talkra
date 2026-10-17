// PopupMode.swift
// OpenClip
//
// Whether the result panel is idle or showing a result card. Never an Action in the registry.
import Foundation

public enum PopupMode: Sendable, Equatable {
    case actions
    case content
}
