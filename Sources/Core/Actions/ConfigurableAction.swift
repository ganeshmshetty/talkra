// ConfigurableAction.swift
// OpenClip
//
// Defines the protocol for actions that expose custom configuration views and icon preferences.
// Allows UI settings surfaces to dynamically display configuration controls and table icons without hardcoding action identifiers.
import Foundation

public protocol ConfigurableAction: Action {
    var preferenceIconName: String { get }
}

public extension ConfigurableAction {
    var preferenceIconName: String {
        switch icon {
        case .symbol(let name):
            return name
        case .local(let url):
            return url.lastPathComponent
        case .url(let url):
            return url.absoluteString
        case .text(let txt):
            return txt
        }
    }
}

