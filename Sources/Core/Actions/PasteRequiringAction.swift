// PasteRequiringAction.swift
// OpenClip
//
// Marks actions that can only perform when the frontmost target app supports Paste (its Edit ▸
// Paste menu item is enabled): the built-in Paste and Cut actions. The registry drops them when
// the input is OCR text. Core is pure — the protocol carries no behavior; the platform probe
// lives in the App target.
import Foundation

/// An action that requires the target app to support Paste. The registry drops it for OCR input.
public protocol PasteRequiringAction {}