// ExtensionsStoreView.swift
// OpenClip
//
// Extension store browsing view for the Actions preferences tab, plus the view model shared with onboarding.
import SwiftUI
import Core

/// Store list order. Replaced an All/Popular/New filter, which hid extensions instead of reordering them.
public enum StoreSort: String, CaseIterable, Identifiable, Sendable {
    /// The catalogue's own order, with the curated showcase on top. The default.
    case featured
    /// Kept for older callers; not offered in the Store menu.
    case name
    case downloads
    case recentlyAdded

    /// Store pages in the sort menu: All, Popular, New.
    public static let allCases: [StoreSort] = [.featured, .downloads, .recentlyAdded]

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .featured: return String(localized: "All")
        case .name: return String(localized: "Name")
        case .downloads: return String(localized: "Popular")
        case .recentlyAdded: return String(localized: "New")
        }
    }

    public var symbol: String {
        switch self {
        case .featured: return "rosette"
        case .name: return "textformat"
        case .downloads: return "arrow.down.circle"
        case .recentlyAdded: return "clock"
        }
    }
}

@MainActor
public final class ExtensionsStoreViewModel: ObservableObject {
    @Published public var searchQuery: String = ""
    @Published public var extensions: [ExtensionItem] = []
    @Published public var featuredItems: [ExtensionItem] = []
    @Published public var newItems: [ExtensionItem] = []
    @Published public var selectedSort: StoreSort = .featured
    @Published public var isLoading: Bool = false
    @Published public var currentPage: Int = 1
    @Published public var totalPages: Int = 1
    @Published public var networkError: String? = nil

    /// Curated featured extensions in priority order (shared with onboarding).
    public static let curatedFeaturedIDs: [String] = [
        "com.openclip.quick-translate",   // Quick Translate
        "com.openclip.runcommand",        // Run in Terminal
        "com.openclip.copy-as-markdown",  // Copy as Markdown
        "com.openclip.shortenlink",       // Shorten Link
    ]

    /// Built-in fallbacks so the Featured showcase renders all 4 items offline or mid-pagination.
    public static let fallbackFeaturedItems: [ExtensionItem] = [
        ExtensionItem(
            id: "com.openclip.quick-translate",
            name: "Quick Translate",
            description: "Translate selected text instantly — result previewed in the popup or pasted in place.",
            author: "Talkra Team",
            icon: "character.bubble",
            downloadCount: 307,
            downloadURL: "https://github.com/ganeshmshetty/openclip-extensions/releases/download/com.openclip.quick-translate@1.0.0/QuickTranslate.openclipext.zip",
            version: "1.0.0",
            iconURL: "https://cdn.jsdelivr.net/gh/ganeshmshetty/openclip-extensions@main/published/icons/com.openclip.quick-translate.svg"
        ),
        ExtensionItem(
            id: "com.openclip.runcommand",
            name: "Run in Terminal",
            description: "Run selected text as a command in Terminal, iTerm, Warp, or Ghostty.",
            author: "Talkra Team",
            icon: "icon.svg",
            downloadCount: 20,
            downloadURL: "https://github.com/ganeshmshetty/openclip-extensions/releases/download/com.openclip.runcommand@1.0.0/RunCommand.openclipext.zip",
            version: "1.0.0",
            iconURL: "https://cdn.jsdelivr.net/gh/ganeshmshetty/openclip-extensions@main/published/icons/com.openclip.runcommand.svg"
        ),
        ExtensionItem(
            id: "com.openclip.copy-as-markdown",
            name: "Copy as Markdown",
            description: "Convert rich text, web selections, and tables into clean Markdown.",
            author: "Talkra Team",
            icon: "icon.svg",
            downloadCount: 35,
            downloadURL: "https://github.com/ganeshmshetty/openclip-extensions/releases/download/com.openclip.copy-as-markdown@1.0.0/CopyAsMarkdown.openclipext.zip",
            version: "1.0.0",
            iconURL: "https://cdn.jsdelivr.net/gh/ganeshmshetty/openclip-extensions@main/published/icons/com.openclip.copy-as-markdown.svg"
        ),
        ExtensionItem(
            id: "com.openclip.shortenlink",
            name: "Shorten Link",
            description: "Shorten the selected URL using TinyURL, is.gd, or v.gd.",
            author: "Talkra Team",
            icon: "icon.svg",
            downloadCount: 25,
            downloadURL: "https://github.com/ganeshmshetty/openclip-extensions/releases/download/com.openclip.shortenlink@1.0.0/ShortenLink.openclipext.zip",
            version: "1.0.0",
            iconURL: "https://cdn.jsdelivr.net/gh/ganeshmshetty/openclip-extensions@main/published/icons/com.openclip.shortenlink.svg"
        )
    ]

    /// Extensions recognized as recent or highlighted catalog additions.
    public static let recentNewIDs: [String] = [
        "com.openclip.render-html",
        "com.openclip.caniuse",
        "com.openclip.devdocs",
        "com.openclip.waybackmachine",
        "com.openclip.logseqcapture",
        "com.openclip.craftdocs",
        "com.openclip.fantasticalevent",
        "com.openclip.wikipedia",
        "com.openclip.applemusic",
    ]

    public func isFeatured(_ item: ExtensionItem) -> Bool {
        if !featuredItems.isEmpty {
            return featuredItems.contains(where: { $0.id.caseInsensitiveCompare(item.id) == .orderedSame })
        }
        return Self.curatedFeaturedIDs.contains(where: { $0.caseInsensitiveCompare(item.id) == .orderedSame })
    }

    public static func isFeatured(_ item: ExtensionItem) -> Bool {
        curatedFeaturedIDs.contains(where: { $0.caseInsensitiveCompare(item.id) == .orderedSame })
    }

    /// How long an extension stays "New" after first added. Mirrored on the website; keep in sync.
    public static let newWindowDays = 14

    /// Floor for the New list so it is never empty: the newest `minimumNewCount` items. Mirrored on the website.
    public static let minimumNewCount = 12

    /// True within `newWindowDays` of first being **added** (`addedAt`, not version or `publishedAt`).
    /// Snapshots without `addedAt` fall back to a `1.0.0` first-release heuristic.
    public static func isNew(_ item: ExtensionItem, now: Date = Date()) -> Bool {
        if let added = item.addedDate {
            guard let cutoff = Calendar(identifier: .gregorian).date(byAdding: .day, value: -newWindowDays, to: now) else {
                return true
            }
            return added >= cutoff
        }
        guard let v = item.version, !v.isEmpty else { return true }
        return v == "1.0.0"
    }

    /// Newest-first by first-added date (falling back to last-release), name as a stable tiebreak.
    private static func addedNewestFirst(_ a: ExtensionItem, _ b: ExtensionItem) -> Bool {
        let da = a.addedDate ?? a.publishedDate ?? .distantPast
        let db = b.addedDate ?? b.publishedDate ?? .distantPast
        if da != db { return da > db }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    /// Items added within `newWindowDays`, topped up to `minimum` with the next most recent. Pure.
    public static func newSelection(_ items: [ExtensionItem], now: Date = Date(), minimum: Int = minimumNewCount) -> [ExtensionItem] {
        let sorted = items.sorted(by: addedNewestFirst)
        let windowed = sorted.filter { isNew($0, now: now) }
        guard windowed.count < minimum else { return windowed }
        let remaining = sorted.filter { !isNew($0, now: now) }
        return windowed + remaining.prefix(minimum - windowed.count)
    }

    /// Curated picks for the Featured section.
    public var featuredSectionItems: [ExtensionItem] {
        if !featuredItems.isEmpty {
            return Array(featuredItems.prefix(4))
        }
        let byID = Dictionary(extensions.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let curated = Self.curatedFeaturedIDs.compactMap { byID[$0.lowercased()] }
        return Array(curated.prefix(4))
    }

    /// Full New list (with the `minimumNewCount` floor). Never empty while the catalogue has items.
    public var newDisplayItems: [ExtensionItem] {
        var seen = Set<String>()
        let pool = (newItems + extensions).filter { seen.insert($0.id.lowercased()).inserted }
        return Self.newSelection(pool)
    }

    /// Four showcase items: new releases first, then updates.
    public var newSectionItems: [ExtensionItem] {
        // A featured extension may also be new; keep it here so the New list stays complete.
        var seen = Set<String>()
        let pool = (newItems + extensions).filter { seen.insert($0.id.lowercased()).inserted }
        let recent = Self.sorted(pool, by: .recentlyAdded, apiNewItems: newItems)
        return Array(recent.prefix(4))
    }

    /// Remaining items for "All Extensions", minus those showcased above.
    public var remainingAllSectionItems: [ExtensionItem] {
        let showcased = Set(featuredSectionItems.map { $0.id.lowercased() } + newSectionItems.map { $0.id.lowercased() })
        return extensions.filter { !showcased.contains($0.id.lowercased()) }
    }

    /// ID of the last rendered item; triggers pagination. Falls back through empty sections.
    public var lastRenderedSectionedItemID: String? {
        remainingAllSectionItems.last?.id
            ?? newSectionItems.last?.id
            ?? featuredSectionItems.last?.id
    }

    /// True when the given item is the final rendered item in the sectioned storefront.
    public func shouldTriggerSectionedPagination(for itemID: String) -> Bool {
        itemID == lastRenderedSectionedItemID
    }

    /// True when the given item is the final rendered item in the flat store list.
    public func shouldTriggerFlatPagination(for itemID: String) -> Bool {
        itemID == flatDisplayedExtensions.last?.id
    }

    /// Orders `items` without dropping any. Pure. `newest` is a rank: the API's "new" list, then
    /// curated recent ids, then items past their first release. Ties keep catalogue order.
    public static func sorted(
        _ items: [ExtensionItem],
        by sort: StoreSort,
        apiNewItems: [ExtensionItem] = []
    ) -> [ExtensionItem] {
        switch sort {
        case .featured:
            return items

        case .name:
            return items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        case .downloads:
            return items.sorted {
                if $0.downloadCount != $1.downloadCount {
                    return $0.downloadCount > $1.downloadCount
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }

        case .recentlyAdded:
            var apiRank: [String: Int] = [:]
            for (index, item) in apiNewItems.enumerated() {
                apiRank[item.id.lowercased()] = index
            }
            let curated = Set(recentNewIDs.map { $0.lowercased() })

            /// Newest first by date; ranks are the fallback for snapshots without `publishedAt`.
            func rank(_ item: ExtensionItem) -> (Int, Int) {
                let id = item.id.lowercased()
                if let position = apiRank[id] { return (0, position) }
                if curated.contains(id) { return (1, 0) }
                return (isNew(item) ? 2 : 3, 0)
            }

            let dated = items.enumerated().filter { $0.element.publishedDate != nil }
            let undated = items.enumerated().filter { $0.element.publishedDate == nil }

            let newestFirst = dated.sorted { left, right in
                let leftDate = left.element.publishedDate ?? .distantPast
                let rightDate = right.element.publishedDate ?? .distantPast
                if leftDate != rightDate { return leftDate > rightDate }
                return left.offset < right.offset
            }
            let ranked = undated.sorted { left, right in
                let leftRank = rank(left.element)
                let rightRank = rank(right.element)
                if leftRank != rightRank { return leftRank < rightRank }
                return left.offset < right.offset
            }

            let recent = (newestFirst + ranked).map(\.element)
            return recent.filter { isNew($0) } + recent.filter { !isNew($0) }
        }
    }

    /// Result-set generation; responses from a superseded generation are discarded.
    private var generation = 0
    /// In-flight debounced search; cancelled when the query changes again.
    private var searchTask: Task<Void, Never>?
    private let api: any ExtensionStoreFetching
    /// Keystroke quiet period before a search actually fires.
    private let debounceNanos: UInt64
    /// Page size; onboarding raises it so one request covers the whole catalog.
    private var pageLimit: Int = Constants.storePageLimit

    public init(api: any ExtensionStoreFetching = ExtensionsAPIClient.shared,
                debounceNanos: UInt64 = 250_000_000) {
        self.api = api
        self.debounceNanos = debounceNanos
    }

    deinit { searchTask?.cancel() }

    public var displayedExtensions: [ExtensionItem] {
        Self.sorted(extensions, by: selectedSort, apiNewItems: newItems)
    }

    /// Rows for the flat store list. New uses the New selection to match the website; searches use only API results.
    public var flatDisplayedExtensions: [ExtensionItem] {
        let ordered = displayedExtensions
        guard selectedSort == .recentlyAdded,
              searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return ordered }
        return newDisplayItems
    }

    /// Debounced, cancellable search for per-keystroke changes; called from `onChange(of: searchQuery)`.
    public func queryDidChange() {
        // Sorting is not a filter, so search results keep the chosen order.
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.debounceNanos)
            guard !Task.isCancelled else { return }
            await self.resetAndFetch(limit: self.pageLimit, keepPrevious: true)
        }
    }

    public func fetchNextPage(isReset: Bool = false, ignoreCache: Bool = false) async {
        let gen = generation
        guard !isLoading || isReset, currentPage <= totalPages else { return }
        isLoading = true

        do {
            let response = try await api.fetchExtensions(query: searchQuery, page: currentPage, limit: pageLimit, ignoreCache: ignoreCache)
            // Superseded mid-flight: touch nothing, not even `isLoading`, which belongs to the newer generation.
            guard gen == generation else { return }
            networkError = nil
            if let featured = response.featured, !featured.isEmpty {
                featuredItems = featured
            }
            if let new = response.new, !new.isEmpty {
                newItems = new
            }
            if isReset {
                extensions = response.extensions
            } else {
                extensions.append(contentsOf: response.extensions)
            }
            totalPages = response.totalPages
            currentPage += 1
            isLoading = false
        } catch is CancellationError {
            guard gen == generation else { return }
            isLoading = false
        } catch {
            guard gen == generation else { return }
            Log.extensions.warning("Failed to fetch extension store page \(self.currentPage) for query '\(self.searchQuery)'")
            if isReset && extensions.isEmpty {
                networkError = error.localizedDescription
                extensions = []
            }
            isLoading = false
        }
    }

    public func resetAndFetch(limit: Int = Constants.storePageLimit, keepPrevious: Bool = false, ignoreCache: Bool = false) async {
        // Bump first so in-flight requests from the previous generation can't append rows or hold the loading flag.
        generation += 1
        pageLimit = limit
        currentPage = 1
        totalPages = 1
        if !keepPrevious {
            extensions = []
            networkError = nil
        }
        isLoading = true
        await fetchNextPage(isReset: true, ignoreCache: ignoreCache)
    }

    /// Loads the whole catalogue, paging until no pages remain, so sorting and counts cover the full set.
    public func loadAll(limit: Int = Constants.storeFullCatalogLimit, keepPrevious: Bool = false, ignoreCache: Bool = false) async {
        generation += 1
        let gen = generation
        pageLimit = limit
        currentPage = 1
        totalPages = 1
        if !keepPrevious {
            extensions = []
            networkError = nil
        }
        isLoading = true
        await fetchNextPage(isReset: true, ignoreCache: ignoreCache)
        // Keep requesting until past the last page; bail if a newer search or reset superseded this load.
        while gen == generation, currentPage <= totalPages, !Task.isCancelled {
            let before = currentPage
            await fetchNextPage(ignoreCache: ignoreCache)
            if currentPage == before { break } // no progress (error / superseded): stop
        }
        if gen == generation { isLoading = false }
    }

    /// Manual refresh: clears cached responses and reloads from the network.
    public func refreshCatalog() async {
        await api.invalidateCache()
        await loadAll(limit: max(pageLimit, Constants.storeFullCatalogLimit), keepPrevious: false, ignoreCache: true)
    }
}

private struct StoreSectionRow: Identifiable {
    let id: String
    let item: ExtensionItem

    init(section: String, item: ExtensionItem) {
        self.id = "\(section):\(item.id.lowercased())"
        self.item = item
    }
}

public struct ExtensionStoreView: View {
    @ObservedObject var viewModel: ExtensionsStoreViewModel

    public init(viewModel: ExtensionsStoreViewModel) {
        self.viewModel = viewModel
    }

    private var isSearching: Bool {
        !viewModel.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public var body: some View {
        // No padding here: the list must reach the top edge so the system fades it under the toolbar.
        storeContent
        .task {
            if viewModel.extensions.isEmpty {
                await viewModel.loadAll(limit: Constants.storeFullCatalogLimit)
            }
        }
    }

    private var storeContent: some View {
        VStack(spacing: 0) {
            if viewModel.extensions.isEmpty && viewModel.isLoading {
                skeletonList
            } else if viewModel.extensions.isEmpty && viewModel.networkError != nil {
                offlineStateView
            } else if viewModel.flatDisplayedExtensions.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "sparkles")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text(isSearching ? String(localized: "No extensions found") : String(localized: "No clips found"))
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !isSearching && viewModel.selectedSort == .featured {
                sectionedAllStoreContent
            } else {
                flatStoreContent
            }
        }
    }

    private var offlineStateView: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "wifi.slash")
                .font(.system(size: 40))
                .foregroundColor(.secondary.opacity(0.8))
            Text(String(localized: "Unable to Connect to Store"))
                .font(.headline)
                .foregroundColor(.primary)
            Text(String(localized: "Check your internet connection or network settings. If you are behind a corporate proxy or firewall, access to the extension store may be blocked."))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button {
                Task {
                    await viewModel.refreshCatalog()
                }
            } label: {
                Label(String(localized: "Try Again"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }

    private var storeHeroHeader: some View {
        VStack(spacing: 10) {
            Image("StoreIcon")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .shadow(color: Color.black.opacity(0.14), radius: 5, x: 0, y: 2.5)

            VStack(spacing: 3) {
                Text(String(localized: "The Clip Store"))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(SettingsDesignTokens.primaryText)
                    .multilineTextAlignment(.center)

                Text(String(localized: "Discover and install extensions for Talkra"))
                    .font(.subheadline)
                    .foregroundStyle(SettingsDesignTokens.secondaryText)
                    .multilineTextAlignment(.center)

                if viewModel.extensions.count > 0 {
                    Text("\(viewModel.extensions.count) extensions")
                        .font(.caption)
                        .foregroundStyle(SettingsDesignTokens.secondaryText.opacity(0.75))
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 10)
    }

    private func sectionHeader(_ title: String, count: Int? = nil) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.headline)
            if let count {
                Text("\(count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 16)
        .padding(.bottom, 6)
    }

    private var sectionedAllStoreContent: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                storeHeroHeader

                if !viewModel.featuredSectionItems.isEmpty {
                    sectionHeader(String(localized: "Featured"))
                    ForEach(Array(viewModel.featuredSectionItems.enumerated()), id: \.element.id) { index, ext in
                        if index > 0 {
                            rowDivider
                        }
                        storeRow(ext)
                    }
                }

                if !viewModel.newSectionItems.isEmpty {
                    sectionHeader(String(localized: "New"))
                    // New may repeat a Featured item; namespace row IDs so SwiftUI doesn't drop the duplicate.
                    ForEach(viewModel.newSectionItems.map { StoreSectionRow(section: "new", item: $0) }) { row in
                        let ext = row.item
                        let index = viewModel.newSectionItems.firstIndex { $0.id == ext.id } ?? 0
                        if index > 0 {
                            rowDivider
                        }
                        storeRow(ext)
                    }
                }

                if !viewModel.remainingAllSectionItems.isEmpty {
                    sectionHeader(
                        String(localized: "All Extensions"),
                        count: viewModel.remainingAllSectionItems.count
                    )
                    ForEach(Array(viewModel.remainingAllSectionItems.enumerated()), id: \.element.id) { index, ext in
                        if index > 0 {
                            rowDivider
                        }
                        storeRow(ext)
                    }
                }
            }
            .padding(.horizontal, 12)
        }
        .opacity(viewModel.isLoading && !viewModel.extensions.isEmpty ? 0.65 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: viewModel.isLoading)
    }

    private var rowDivider: some View {
        Divider()
            .padding(.leading, 60)
            .padding(.trailing, 14)
    }

    private func storeRow(_ ext: ExtensionItem) -> some View {
        ExtensionCardView(item: ext, isFeatured: viewModel.isFeatured(ext))
            .onAppear {
                if viewModel.shouldTriggerSectionedPagination(for: ext.id) {
                    Task { await viewModel.fetchNextPage() }
                }
            }
    }

    private var flatSectionTitle: String {
        if isSearching {
            return String(localized: "Search Results")
        }
        switch viewModel.selectedSort {
        case .featured, .name:
            return String(localized: "All Extensions")
        case .downloads:
            return String(localized: "Popular")
        case .recentlyAdded:
            return String(localized: "New")
        }
    }

    private var flatStoreContent: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if !isSearching {
                    storeHeroHeader
                }

                sectionHeader(flatSectionTitle, count: viewModel.flatDisplayedExtensions.count)

                ForEach(Array(viewModel.flatDisplayedExtensions.enumerated()), id: \.element.id) { index, ext in
                    if index > 0 {
                        rowDivider
                    }
                    ExtensionCardView(item: ext, isFeatured: viewModel.isFeatured(ext))
                        .onAppear {
                            if viewModel.shouldTriggerFlatPagination(for: ext.id) {
                                Task { await viewModel.fetchNextPage() }
                            }
                        }
                }
            }
            .padding(.horizontal, 12)
        }
        .opacity(viewModel.isLoading && !viewModel.extensions.isEmpty ? 0.65 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: viewModel.isLoading)
    }

    private var skeletonList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(0..<6, id: \.self) { index in
                    if index > 0 {
                        Divider()
                            .padding(.leading, 60)
                            .padding(.trailing, 14)
                    }
                    ExtensionCardSkeletonRow()
                }
            }
            .padding(.horizontal, 12)
        }
    }
}

// MARK: - Extension Card Skeleton Row

private struct ExtensionCardSkeletonRow: View {
    @State private var isPulsing = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.07))
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(0.10))
                        .frame(width: 110, height: 12)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                        .frame(width: 60, height: 10)
                }
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: 220, height: 11)
            }

            Spacer()

            RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                .fill(Color.primary.opacity(0.07))
                .frame(width: 26, height: 26)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .opacity(isPulsing ? 0.35 : 0.85)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }
}
