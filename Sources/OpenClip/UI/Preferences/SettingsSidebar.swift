// SettingsSidebar.swift
// OpenClip
//
// The window's table of contents: a fixed-width sidebar on the window background with a search capsule,
// ~30pt rows, ~20pt icon tiles, a translucent (not accent) selection, and hidden scroll indicators.

import SwiftUI
import AppKit
import Core

extension SettingKey where Value == Bool {
    static var preferencesActionsSectionExpanded: SettingKey<Bool> {
        SettingKey<Bool>("preferencesSidebar.actionsExpanded", defaultValue: true)
    }

    static var preferencesInstalledSectionExpanded: SettingKey<Bool> {
        SettingKey<Bool>("preferencesSidebar.installedExpanded", defaultValue: true)
    }
}

// MARK: - Rows

/// One sidebar row, resolved to strings so the filter can run over it without touching the models.
struct SettingsSidebarRow: Identifiable {
    enum Tile {
        case symbol(String, tint: Color)
        case icon(ActionIcon, tint: Color)
        case bare(ActionIcon)
    }

    let page: SettingsPage
    let title: String
    let keywords: [String]
    let tile: Tile
    let isDisabled: Bool

    var id: String { page.id }

    init(page: SettingsPage, title: String, keywords: [String] = [], tile: Tile, isDisabled: Bool = false) {
        self.page = page
        self.title = title
        self.keywords = keywords
        self.tile = tile
        self.isDisabled = isDisabled
    }

    /// A system page row: title, glyph and search terms come from the page itself.
    init(systemPage page: SettingsPage, isDisabled: Bool = false) {
        self.init(
            page: page,
            title: page.staticTitle ?? page.id,
            keywords: page.searchKeywords,
            tile: .symbol(page.systemImage, tint: SettingsDesignTokens.iconTileColor(for: page)),
            isDisabled: isDisabled
        )
    }

    /// Whether the row answers `query`: every query word must appear in the title or keywords.
    func matches(_ query: String) -> Bool {
        let words = Self.words(in: query)
        guard !words.isEmpty else { return true }
        let haystack = ([title] + keywords).map { $0.lowercased() }
        return words.allSatisfy { word in haystack.contains { $0.contains(word) } }
    }

    static func words(in query: String) -> [String] {
        query.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}

/// Order of the second group: shipped items first, then installed; alphabetical within a rank.
enum SettingsSidebarOrder {
    /// Lower sorts first: AI, built-in actions, custom actions, then installed extensions.
    static func rank(of page: SettingsPage) -> Int {
        switch page {
        case .ai: return 0
        case .builtinAction: return 1
        case .customActions: return 2
        case .extensionPackage: return 3
        default: return 4
        }
    }

    /// Installed packages sit after a gap, separate from the shipped block.
    static func isInstalledExtension(_ page: SettingsPage) -> Bool {
        if case .extensionPackage = page { return true }
        return false
    }

    /// The second group cut in two at that line, each half still in `sorted` order.
    static func split(
        _ rows: [SettingsSidebarRow]
    ) -> (bundled: [SettingsSidebarRow], installed: [SettingsSidebarRow]) {
        (rows.filter { !isInstalledExtension($0.page) }, rows.filter { isInstalledExtension($0.page) })
    }

    static func sorted(_ rows: [SettingsSidebarRow]) -> [SettingsSidebarRow] {
        rows.sorted { left, right in
            let leftRank = rank(of: left.page)
            let rightRank = rank(of: right.page)
            if leftRank != rightRank { return leftRank < rightRank }
            return left.title.localizedStandardCompare(right.title) == .orderedAscending
        }
    }
}

enum SettingsSidebarFilter {
    static func filter(_ rows: [SettingsSidebarRow], query: String) -> [SettingsSidebarRow] {
        guard !SettingsSidebarRow.words(in: query).isEmpty else { return rows }
        return rows.filter { $0.matches(query) }
    }
}

/// Stable palette and hash-based tints for extensions.
enum SettingsTint {
    static let general = Color(nsColor: .systemGray)
    static let appearance = Color(red: 0.95, green: 0.35, blue: 0.60)
    static let customize = Color(red: 0.65, green: 0.35, blue: 0.95)
    static let shortcuts = Color(red: 0.68, green: 0.35, blue: 0.98)
    static let appRules = Color(red: 0.98, green: 0.52, blue: 0.12)
    static let ai = Color(red: 0.10, green: 0.72, blue: 0.84)
    static let store = Color(red: 0.05, green: 0.52, blue: 0.98)
    static let about = Color(red: 0.20, green: 0.78, blue: 0.42)
    static let neutral = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(red: 0.22, green: 0.22, blue: 0.25, alpha: 1.0)
        } else {
            return NSColor(red: 0.55, green: 0.55, blue: 0.58, alpha: 1.0)
        }
    }))

    static var openClip: Color {
        Color.accentColor
    }

    static let reservedBlueHues: Range<Int> = 190..<270

    static func extensionTint(for packageID: String) -> Color {
        Color(hue: Double(hue(for: packageID)) / 360.0, saturation: 0.74, brightness: 0.88)
    }

    static func hue(for packageID: String) -> Int {
        var hash = 0
        for byte in packageID.utf8 {
            hash = (hash &* 31 &+ Int(byte)) % 360
        }
        let available = 360 - reservedBlueHues.count
        var value = ((hash % available) + available) % available
        if value >= reservedBlueHues.lowerBound {
            value += reservedBlueHues.count
        }
        return value
    }
}

// MARK: - Tiles

/// The ~20pt coloured rounded square with a white glyph on front of every sidebar row.
struct SettingsIconTile: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = SettingsDesignTokens.iconTileSize

    var body: some View {
        SettingsTileBackground(tint: tint, size: size)
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.56, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.2), radius: 0.5, y: 0.5)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The same tile for an extension, drawing whatever icon the package ships.
struct ExtensionIconTile: View {
    let icon: ActionIcon
    let tint: Color
    var size: CGFloat = SettingsDesignTokens.iconTileSize

    var body: some View {
        SettingsTileBackground(tint: tint, size: size)
            .overlay {
                switch icon {
                case .text(let text):
                    Text(String(text.trimmingCharacters(in: .whitespaces).prefix(2)))
                        .font(.system(size: size * 0.48, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                default:
                    ActionIconView(icon: icon, size: size * 0.58)
                        .foregroundStyle(.white)
                        .frame(width: size * 0.72, height: size * 0.72)
                        .clipped()
                }
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct SettingsTileBackground: View {
    let tint: Color
    let size: CGFloat

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: SettingsDesignTokens.iconTileRadius(for: size), style: .continuous)
    }

    var body: some View {
        shape
            .fill(
                LinearGradient(
                    colors: [tint.opacity(0.96), tint],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay {
                shape.fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.18), Color.white.opacity(0.0)],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
            }
    }
}

// MARK: - Sidebar

@MainActor
struct SettingsSidebar: View {
    @Binding var selection: SettingsPage?
    // Keep typing local: changing this must not invalidate the entire preferences detail pane.
    @State private var query = ""
    @State private var searchIndex = PreferencesSearch.Index(entries: [])
    @State private var searchResults: [PreferencesSearchEntry] = []
    @State private var searchResultIDs: [String] = []
    let systemRows: [SettingsSidebarRow]
    var searchEntries: [PreferencesSearchEntry] = []
    var onOpenSearchResult: (PreferencesSearchEntry) -> Void = { _ in }
    var onSearchStore: (String) -> Void = { _ in }
    var extensionRows: [SettingsSidebarRow] = []
    @State private var hoveredRowID: String? = nil
    @State private var selectedSearchID: String?
    private static let storeSearchID = "preferences-search-store"
    @FocusState private var searchFocused: Bool

    private var filteredSystemRows: [SettingsSidebarRow] {
        SettingsSidebarFilter.filter(systemRows, query: query)
    }

    private var hasResults: Bool {
        !filteredSystemRows.isEmpty
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var activeSearchID: String? {
        if let selectedSearchID, (searchResultIDs + [Self.storeSearchID]).contains(selectedSearchID) {
            return selectedSearchID
        }
        return searchResults.first?.id
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                // Top area: space for traffic lights + capsule search field
                VStack(spacing: 12) {
                    Color.clear
                        .frame(height: 38)

                    searchField
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if isSearching {
                            searchResultsView
                        } else if !filteredSystemRows.isEmpty {
                            ForEach(filteredSystemRows) { row in
                                rowView(row)
                                    .id(row.page.id)
                            }
                        }

                        if !isSearching && !hasResults {
                            Text(String(localized: "No Results"))
                                .font(.callout)
                                .foregroundStyle(SettingsDesignTokens.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 24)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
                .scrollContentBackground(.hidden)
            }
            .frame(width: SettingsDesignTokens.sidebarWidth)
            .background(Color.clear)
            .onAppear { scrollSelectionIntoView(proxy, animated: false) }
            .onChange(of: searchEntries, initial: true) { _, entries in
                searchIndex = PreferencesSearch.Index(entries: entries)
                refreshSearchResults()
            }
            .onChange(of: query) { _, newValue in
                selectedSearchID = nil
                refreshSearchResults()
                if newValue.isEmpty { scrollSelectionIntoView(proxy, animated: true) }
                else if let first = searchResults.first { proxy.scrollTo(first.id, anchor: .top) }
            }
            .onChange(of: activeSearchID) { _, id in
                if let id, isSearching { proxy.scrollTo(id) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openClipPreferencesWindowDidShow)) { _ in
                scrollSelectionIntoView(proxy, animated: false)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SettingsDesignTokens.sidebarSearchPlaceholder)
                .padding(.leading, 8)

            TextField(String(localized: "Search settings..."), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(SettingsDesignTokens.primaryText)
                .focused($searchFocused)
                .accessibilityLabel(String(localized: "Search settings"))
                .onKeyPress(.escape) {
                    guard !query.isEmpty else { return .ignored }
                    query = ""
                    return .handled
                }
                .onKeyPress(.downArrow) { moveSearchSelection(1) }
                .onKeyPress(.upArrow) { moveSearchSelection(-1) }
                .onSubmit { openSelectedSearchResult() }

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsDesignTokens.sidebarSearchPlaceholder)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
            }
        }
        .frame(height: 28)
        .settingsGlassCapsule(interactive: false)
    }

    private var searchResultsView: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(searchResults) { entry in
                Button {
                    openSearchResult(entry)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.title)
                            .font(.system(size: 13))
                            .foregroundStyle(SettingsDesignTokens.primaryText)
                            .lineLimit(1)
                        Text(entry.breadcrumb)
                            .font(.system(size: 11))
                            .foregroundStyle(SettingsDesignTokens.secondaryText)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .background(searchRowBackground(for: entry.id))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .id(entry.id)
                .accessibilityLabel(entry.title)
                .accessibilityValue(entry.breadcrumb)
                .accessibilityAddTraits(activeSearchID == entry.id ? .isSelected : [])
                .onHover { updateSearchHover(entry.id, hovering: $0) }
            }

            if searchResults.isEmpty {
                Text(String(localized: "No Results"))
                    .font(.callout)
                    .foregroundStyle(SettingsDesignTokens.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            }

            Divider()
                .padding(.horizontal, 8)
                .padding(.vertical, 7)

            Button {
                openStoreSearch()
            } label: {
                HStack(spacing: 9) {
                    Text(storeSearchTitle)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .medium))
                }
                .font(.system(size: 12))
                .foregroundStyle(SettingsDesignTokens.secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .background(searchRowBackground(for: Self.storeSearchID))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .id(Self.storeSearchID)
            .accessibilityLabel(storeSearchTitle)
            .accessibilityAddTraits(activeSearchID == Self.storeSearchID ? .isSelected : [])
            .onHover { updateSearchHover(Self.storeSearchID, hovering: $0) }
        }
    }

    private var storeSearchTitle: String {
        String(format: String(localized: "Search Store for “%@”"), query.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func refreshSearchResults() {
        let results = searchIndex.results(query: query)
        searchResults = results
        searchResultIDs = results.map(\.id)
    }

    private func openSearchResult(_ entry: PreferencesSearchEntry) {
        onOpenSearchResult(entry)
        query = ""
    }

    private func openStoreSearch() {
        onSearchStore(query.trimmingCharacters(in: .whitespacesAndNewlines))
        query = ""
    }

    private func searchRowBackground(for id: String) -> some View {
        RoundedRectangle(cornerRadius: SettingsDesignTokens.sidebarSelectionRadius, style: .continuous)
            .fill(activeSearchID == id ? SettingsDesignTokens.selectedRowBackground
                  : hoveredRowID == id ? SettingsDesignTokens.hoveredRowBackground : Color.clear)
    }

    private func updateSearchHover(_ id: String, hovering: Bool) {
        if hovering { hoveredRowID = id }
        else if hoveredRowID == id { hoveredRowID = nil }
    }

    private func moveSearchSelection(_ direction: Int) -> KeyPress.Result {
        guard isSearching else { return .ignored }
        selectedSearchID = PreferencesSearch.movedSelection(
            from: activeSearchID, in: searchResultIDs + [Self.storeSearchID], direction: direction
        )
        return .handled
    }

    private func openSelectedSearchResult() {
        if activeSearchID == Self.storeSearchID {
            openStoreSearch()
        } else if let entry = searchResults.first(where: { $0.id == activeSearchID }) {
            openSearchResult(entry)
        }
    }

    private func rowView(_ row: SettingsSidebarRow) -> some View {
        let isSelected = selection == row.page
        let isHovered = hoveredRowID == row.id && !isSelected

        return Button {
            selection = row.page
        } label: {
            HStack(spacing: 10) {
                switch row.tile {
                case .symbol(let name, let tint):
                    SettingsIconTile(systemImage: name, tint: tint, size: SettingsDesignTokens.iconTileSize)
                case .icon(let icon, let tint):
                    ExtensionIconTile(icon: icon, tint: tint, size: SettingsDesignTokens.iconTileSize)
                case .bare(let icon):
                    ActionIconView(icon: icon, size: 14)
                        .foregroundStyle(isSelected ? SettingsDesignTokens.primaryText : SettingsDesignTokens.secondaryText)
                        .frame(width: SettingsDesignTokens.iconTileSize, height: SettingsDesignTokens.iconTileSize, alignment: .center)
                }

                Text(row.title)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(SettingsDesignTokens.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: SettingsDesignTokens.sidebarRowPitch)
            .background(
                RoundedRectangle(cornerRadius: SettingsDesignTokens.sidebarSelectionRadius, style: .continuous)
                    .fill(isSelected ? SettingsDesignTokens.selectedRowBackground : (isHovered ? SettingsDesignTokens.hoveredRowBackground : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(row.isDisabled ? Text("Disabled") : Text(""))
        .onHover { hovering in
            if hovering {
                hoveredRowID = row.id
            } else if hoveredRowID == row.id {
                hoveredRowID = nil
            }
        }
        .opacity(row.isDisabled ? 0.45 : 1.0)
        .saturation(row.isDisabled ? 0.5 : 1.0)
    }

    private func scrollSelectionIntoView(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let page = selection else { return }
        let scroll = { proxy.scrollTo(page.id) }
        if animated {
            withAnimation(.easeInOut(duration: 0.18)) { scroll() }
        } else {
            DispatchQueue.main.async { scroll() }
        }
    }
}
