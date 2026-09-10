import SwiftUI

struct YUTorahSearchView: View {
    let onSelectTeacher: (Int, String, [RemoteShiurItem]) -> Void
    let onSelectSeries: (Int, String, [RemoteShiurItem]) -> Void
    let onSelectCollection: (Int, String, [RemoteShiurItem]) -> Void
    let onSelectShiur: (RemoteShiurItem) -> Void

    var subscriptionsContent: () -> AnyView = { AnyView(EmptyView()) }

    @State private var query = ""
    @State private var isSearching = false
    @State private var searchResults: YUTorahSearchResults = .empty
    @State private var selectedTab: SearchTab = .overview
    @State private var searchTask: Task<Void, Never>?
    @State private var searchRequestID = UUID()

    // Active Drilldown Filters
    @State private var activeTeacher: YUTorahFacetTeacher? = nil
    @State private var activeSubcategory: YUTorahFacetSubcategory? = nil

    // Pagination & Expanded Collections
    @State private var isLoadingMoreShiurim = false
    @State private var expandedCollectionID: Int? = nil
    @State private var expandedCollectionShiurim: [RemoteShiurItem] = []
    @State private var isLoadingCollectionShiurim = false

    private let searchService = YUTorahSearchService()

    enum SearchTab: String, CaseIterable, Identifiable {
        case overview = "Top Results"
        case shiurim = "Shiurim"
        case collections = "Collections"
        case series = "Series"
        case teachers = "Teachers"
        case topics = "Topics"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            searchBar

            if activeTeacher != nil || activeSubcategory != nil {
                activeFilterBanner
            }

            if shouldShowContent {
                if let message = searchResults.failureMessage {
                    HStack {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Retry") { performDebouncedSearch(query) }
                            .disabled(isSearching)
                    }
                }
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text(activeTeacher == nil ? "Search YU Torah" : "Explore this teacher")
                            .font(.system(size: 23, weight: .semibold, design: .serif))
                        Spacer()
                        if isSearching {
                            Text("Searching…").foregroundStyle(.secondary)
                        } else {
                            Text("\(searchResults.totalShiurim.formatted()) shiurim")
                                .foregroundStyle(.secondary)
                        }
                    }
                    tabBar
                    tabContent
                }
            } else {
                subscriptionsContent()
                discoverySection
            }
        }
    }

    private var shouldShowContent: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty || activeTeacher != nil
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(.secondary)

            TextField(
                activeTeacher == nil
                    ? "Search teachers, series, collections, or shiurim…"
                    : "Search within \(activeTeacher!.displayName)...",
                text: $query
            )
            .textFieldStyle(.plain)
            .font(.system(size: 16))
            .onChange(of: query) { _, newQuery in
                performDebouncedSearch(newQuery)
            }

            if isSearching {
                ProgressView()
                    .controlSize(.small)
            } else if !query.isEmpty {
                Button {
                    query = ""
                    if activeTeacher != nil {
                        performTeacherSearch(activeTeacher!)
                    } else {
                        searchResults = .empty
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LecternTheme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(LecternTheme.hairline, lineWidth: 1)
        )
    }

    // MARK: - Active Filter Banner

    @ViewBuilder
    private var activeFilterBanner: some View {
        HStack(spacing: 12) {
            if let teacher = activeTeacher {
                YUTorahSourcePortrait(teacherID: teacher.id, size: 56)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(teacher.displayName)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(LecternTheme.ink)

                        Text("\(searchResults.activeTeacher?.shiurCount ?? teacher.shiurCount) shiurim")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.10), in: Capsule())
                    }

                    if let sub = activeSubcategory {
                        Text("Filtered by Topic: \(sub.title)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Browsing all shiurim, collections, and series by this speaker")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                HStack(spacing: 8) {
                    Button {
                        onSelectTeacher(teacher.id, teacher.displayName, searchResults.shiurim)
                    } label: {
                        Label("Subscribe to Speaker", systemImage: "bell.fill")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(LecternTheme.accent, in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)

                    Button {
                        activeTeacher = nil
                        activeSubcategory = nil
                        performDebouncedSearch(query)
                    } label: {
                        Text("All Speakers")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                }
            } else if let sub = activeSubcategory {
                Text("Topic: \(sub.title)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.purple)

                Spacer()

                Button("Clear Topic") {
                    activeSubcategory = nil
                    performDebouncedSearch(query)
                }
                .font(.system(size: 11))
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.blue.opacity(0.18), lineWidth: 1)
        )
    }

    // MARK: - Category Tab Bar

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(visibleTabs) { tab in
                    tabButton(tab)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var visibleTabs: [SearchTab] {
        var tabs: [SearchTab] = [.overview, .shiurim, .collections, .series]
        if activeTeacher == nil {
            tabs.append(.teachers)
        }
        if !searchResults.subcategories.isEmpty {
            tabs.append(.topics)
        }
        return tabs
    }

    private func tabButton(_ tab: SearchTab) -> some View {
        let isSelected = selectedTab == tab
        let countString = tabCountString(for: tab)

        return Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 5) {
                Text(tab.rawValue)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))

                if let count = countString {
                    Text(count)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isSelected ? LecternTheme.accent : .secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            isSelected ? LecternTheme.accent.opacity(0.15) : Color.primary.opacity(0.06),
                            in: Capsule()
                        )
                }
            }
            .foregroundStyle(isSelected ? LecternTheme.accent : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                isSelected ? LecternTheme.accent.opacity(0.10) : Color.primary.opacity(0.03),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
    }

    private func tabCountString(for tab: SearchTab) -> String? {
        switch tab {
        case .overview:
            return nil
        case .shiurim:
            let count = searchResults.totalShiurim
            return count > 9999 ? "\(count / 1000)k" : "\(count)"
        case .collections:
            return "\(searchResults.collections.count)"
        case .series:
            return "\(searchResults.series.count)"
        case .teachers:
            return "\(searchResults.teachers.count)"
        case .topics:
            return "\(searchResults.subcategories.count)"
        }
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        if searchResults.isEmpty && !isSearching {
            emptyStateView
        } else {
            VStack(alignment: .leading, spacing: 10) {
                switch selectedTab {
                case .overview:
                    overviewView
                case .shiurim:
                    shiurimView
                case .collections:
                    collectionsView
                case .series:
                    seriesView
                case .teachers:
                    teachersView
                case .topics:
                    topicsView
                }
            }
            .frame(height: 540)
        }
    }

    private var emptyStateView: some View {
        HStack {
            Text("No matching YU Torah results found.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 12)
    }

    // MARK: - 1. Overview Tab

    private var overviewView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Matching Teachers Carousel if not drilled in
                if activeTeacher == nil && !searchResults.teachers.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Matching teachers")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(LecternTheme.ink)
                            Spacer()
                            Button("View All (\(searchResults.teachers.count))") {
                                selectedTab = .teachers
                            }
                            .font(.system(size: 11))
                            .buttonStyle(.plain)
                            .foregroundStyle(LecternTheme.accent)
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(searchResults.teachers.prefix(6)) { teacher in
                                    teacherCard(teacher).frame(width: 290)
                                }
                            }
                        }
                    }
                }

                // Top Collections Preview
                if !searchResults.collections.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Collections")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(LecternTheme.ink)
                            Spacer()
                            Button("View All (\(searchResults.collections.count))") {
                                selectedTab = .collections
                            }
                            .font(.system(size: 11))
                            .buttonStyle(.plain)
                            .foregroundStyle(LecternTheme.accent)
                        }

                        VStack(spacing: 6) {
                            ForEach(searchResults.collections.prefix(3)) { collection in
                                collectionRow(collection)
                            }
                        }
                    }
                }

                // Top Series Preview
                if !searchResults.series.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Series")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(LecternTheme.ink)
                            Spacer()
                            Button("View All (\(searchResults.series.count))") {
                                selectedTab = .series
                            }
                            .font(.system(size: 11))
                            .buttonStyle(.plain)
                            .foregroundStyle(LecternTheme.accent)
                        }

                        VStack(spacing: 6) {
                            ForEach(searchResults.series.prefix(3)) { series in
                                seriesRow(series)
                            }
                        }
                    }
                }

                // Recent / Matching Shiurim Preview
                if !searchResults.shiurim.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Shiurim (\(searchResults.totalShiurim.formatted()))")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(LecternTheme.ink)
                            Spacer()
                            Button("View All") {
                                selectedTab = .shiurim
                            }
                            .font(.system(size: 11))
                            .buttonStyle(.plain)
                            .foregroundStyle(LecternTheme.accent)
                        }

                        VStack(spacing: 4) {
                            ForEach(searchResults.shiurim.prefix(5)) { shiur in
                                shiurRow(shiur)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - 2. Shiurim Tab

    private var shiurimView: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(searchResults.shiurim) { shiur in
                    shiurRow(shiur)
                }

                if searchResults.currentPage < searchResults.totalPages {
                    Button {
                        loadMoreShiurim()
                    } label: {
                        HStack(spacing: 6) {
                            if isLoadingMoreShiurim {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.down.circle")
                            }
                            Text("Load More Shiurim")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                    .disabled(isLoadingMoreShiurim)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - 3. Collections Tab

    private var collectionsView: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(searchResults.collections) { collection in
                    collectionRow(collection)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - 4. Series Tab

    private var seriesView: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(searchResults.series) { series in
                    seriesRow(series)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - 5. Teachers Tab

    private var teachersView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 14)], spacing: 14) {
                ForEach(searchResults.teachers) { teacher in
                    teacherCard(teacher)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - 6. Topics Tab

    private var topicsView: some View {
        ScrollView {
            FlowLayout(spacing: 8) {
                ForEach(searchResults.subcategories) { subcat in
                    Button {
                        activeSubcategory = subcat
                        selectedTab = .shiurim
                        performSubcategoryFilter(subcat)
                    } label: {
                        HStack(spacing: 5) {
                            Text(subcat.title)
                                .font(.system(size: 12))
                                .foregroundStyle(LecternTheme.ink)

                            Text("\(subcat.shiurCount)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.primary.opacity(0.06), in: Capsule())
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Row & Card Views

    private var discoverySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Discover on YU Torah")
                    .font(.system(size: 23, weight: .semibold, design: .serif))
                    .foregroundStyle(LecternTheme.ink)
                Text("Recommended teachers for your next shiur.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                ForEach(YUTorahRecommendedTeacher.all) { teacher in
                    recommendationCard(teacher)
                }
            }
        }
        .padding(.top, 6)
    }

    private func recommendationCard(_ teacher: YUTorahRecommendedTeacher) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                YUTorahSourcePortrait(teacherID: teacher.id, size: 54)
                Text(teacher.name)
                    .font(.system(size: 14, weight: .semibold, design: .serif))
                    .foregroundStyle(LecternTheme.ink)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            }
            HStack(spacing: 8) {
                Button("Browse") {
                    performTeacherSearch(YUTorahFacetTeacher(id: teacher.id, rawName: teacher.name,
                                                            lastName: nil, shiurCount: 0))
                }
                .foregroundStyle(.secondary)
                Button {
                    onSelectTeacher(teacher.id, teacher.name, [])
                } label: {
                    Text("Subscribe").frame(maxWidth: .infinity).padding(.vertical, 7)
                        .foregroundStyle(LecternTheme.accent)
                        .background(LecternTheme.accent.opacity(0.09), in: Capsule())
                }
            }
            .font(.system(size: 12, weight: .medium)).buttonStyle(.plain)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(LecternTheme.cardFill, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(LecternTheme.hairline))
    }

    private func teacherCard(_ teacher: YUTorahFacetTeacher) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                YUTorahSourcePortrait(teacherID: teacher.id, size: 60)
                VStack(alignment: .leading, spacing: 6) {
                    Text(teacher.displayName)
                        .font(.system(size: 16, weight: .semibold, design: .serif))
                        .foregroundStyle(LecternTheme.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(teacher.shiurCount.formatted()) shiurim")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Button { performTeacherSearch(teacher) } label: {
                    Text("Browse shiurim")
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                }
                Button {
                    // General search results can include unrelated speakers.
                    onSelectTeacher(teacher.id, teacher.displayName, [])
                } label: {
                    Text("Subscribe")
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .foregroundStyle(LecternTheme.accent)
                        .background(LecternTheme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                }
            }
            .font(.system(size: 12, weight: .medium)).buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(LecternTheme.cardFill, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(LecternTheme.hairline))
    }

    private func collectionRow(_ collection: YUTorahFacetCollection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.teal.opacity(0.12))
                        .frame(width: 28, height: 28)
                    Image(systemName: "folder.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.teal)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(collection.title)
                        .font(.system(size: 15, weight: .medium, design: .serif))
                        .foregroundStyle(LecternTheme.ink)
                        .lineLimit(1)

                    Text("\(collection.shiurCount) Shiurim")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 6) {
                    Button {
                        toggleExpandCollection(collection)
                    } label: {
                        Text(expandedCollectionID == collection.id ? "Hide" : "View Shiurim")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.primary.opacity(0.05), in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        onSelectCollection(collection.id, collection.title, [])
                    } label: {
                        Text("Subscribe")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(LecternTheme.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(LecternTheme.accent.opacity(0.10), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            if expandedCollectionID == collection.id {
                if isLoadingCollectionShiurim {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Loading collection shiurim...")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 38)
                    .padding(.vertical, 4)
                } else if !expandedCollectionShiurim.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(expandedCollectionShiurim) { shiur in
                            shiurRow(shiur)
                        }
                    }
                    .padding(.leading, 24)
                    .padding(.top, 4)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LecternTheme.cardFill)
        )
    }

    private func seriesRow(_ series: YUTorahFacetSeries) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.orange.opacity(0.12))
                    .frame(width: 28, height: 28)
                Image(systemName: "books.vertical")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(series.title)
                    .font(.system(size: 15, weight: .medium, design: .serif))
                    .foregroundStyle(LecternTheme.ink)
                    .lineLimit(1)

                Text("\(series.shiurCount) Shiurim")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                onSelectSeries(series.id, series.title, [])
            } label: {
                Text("Subscribe")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LecternTheme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(LecternTheme.accent.opacity(0.10), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LecternTheme.cardFill)
        )
    }

    private func shiurRow(_ item: RemoteShiurItem) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.purple.opacity(0.10))
                    .frame(width: 28, height: 28)
                Image(systemName: "waveform")
                    .font(.system(size: 12))
                    .foregroundStyle(.purple)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 15, weight: .medium, design: .serif))
                    .foregroundStyle(LecternTheme.ink)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if let teacher = item.teacherName {
                        Text(teacher)
                    }
                    if let series = item.seriesName {
                        Text("·")
                        Text(series)
                    }
                    Text("·")
                    Text(item.date.formatted(date: .abbreviated, time: .omitted))
                    if let duration = item.duration, duration > 0 {
                        Text("·")
                        Text("\(Int(duration / 60)) min")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            Button {
                onSelectShiur(item)
            } label: {
                Text("Import")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LecternTheme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(LecternTheme.accent.opacity(0.10), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LecternTheme.cardFill)
        )
    }

    // MARK: - Actions & Search Logic

    private func performDebouncedSearch(_ text: String) {
        searchTask?.cancel()
        searchRequestID = UUID()
        isLoadingMoreShiurim = false
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || activeTeacher != nil else {
            searchResults = .empty
            isSearching = false
            return
        }

        isSearching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }

            let results = await searchService.searchStructured(
                query: trimmed,
                teacherID: activeTeacher?.id,
                subcategoryID: activeSubcategory?.id,
                page: 1
            )
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard !Task.isCancelled else { return }
                self.searchResults = results
                self.isSearching = false
            }
        }
    }

    private func performTeacherSearch(_ teacher: YUTorahFacetTeacher) {
        activeTeacher = teacher
        activeSubcategory = nil
        query = ""
        selectedTab = .overview
        isSearching = true

        searchTask?.cancel()
        searchRequestID = UUID()
        isLoadingMoreShiurim = false
        searchTask = Task {
            let results = await searchService.searchStructured(
                query: query.trimmingCharacters(in: .whitespacesAndNewlines),
                teacherID: teacher.id,
                page: 1
            )
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self.searchResults = results
                self.isSearching = false
            }
        }
    }

    private func performSubcategoryFilter(_ subcategory: YUTorahFacetSubcategory) {
        isSearching = true
        searchTask?.cancel()
        searchRequestID = UUID()
        isLoadingMoreShiurim = false
        searchTask = Task {
            let results = await searchService.searchStructured(
                query: query.trimmingCharacters(in: .whitespacesAndNewlines),
                teacherID: activeTeacher?.id,
                subcategoryID: subcategory.id,
                page: 1
            )
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self.searchResults = results
                self.isSearching = false
            }
        }
    }

    private func loadMoreShiurim() {
        guard !isLoadingMoreShiurim, searchResults.currentPage < searchResults.totalPages else { return }
        isLoadingMoreShiurim = true
        let nextPage = searchResults.currentPage + 1
        let requestID = searchRequestID

        Task {
            let nextResults = await searchService.searchStructured(
                query: query.trimmingCharacters(in: .whitespacesAndNewlines),
                teacherID: activeTeacher?.id,
                subcategoryID: activeSubcategory?.id,
                page: nextPage
            )

            await MainActor.run {
                guard requestID == searchRequestID else { return }
                if let message = nextResults.failureMessage {
                    searchResults.failureMessage = message
                    isLoadingMoreShiurim = false
                    return
                }
                var combinedShiurim = self.searchResults.shiurim
                var seen = Set(combinedShiurim.map(\.shiurID))
                for item in nextResults.shiurim where !seen.contains(item.shiurID) {
                    seen.insert(item.shiurID)
                    combinedShiurim.append(item)
                }

                self.searchResults = YUTorahSearchResults(
                    query: self.searchResults.query,
                    totalShiurim: self.searchResults.totalShiurim,
                    currentPage: nextPage,
                    totalPages: self.searchResults.totalPages,
                    shiurim: combinedShiurim,
                    teachers: self.searchResults.teachers,
                    collections: self.searchResults.collections,
                    series: self.searchResults.series,
                    subcategories: self.searchResults.subcategories,
                    activeTeacher: self.searchResults.activeTeacher,
                    activeSubcategory: self.searchResults.activeSubcategory
                )
                self.isLoadingMoreShiurim = false
            }
        }
    }

    private func toggleExpandCollection(_ collection: YUTorahFacetCollection) {
        if expandedCollectionID == collection.id {
            expandedCollectionID = nil
            expandedCollectionShiurim = []
        } else {
            expandedCollectionID = collection.id
            isLoadingCollectionShiurim = true
            Task {
                let shiurim = await searchService.fetchCollectionShiurim(collectionID: collection.id)
                await MainActor.run {
                    self.expandedCollectionShiurim = shiurim
                    self.isLoadingCollectionShiurim = false
                }
            }
        }
    }
}

// FlowLayout for tag wrapping in Topics tab
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 500
        var height: CGFloat = 0
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var maxHeightInRow: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > width && currentX > 0 {
                currentX = 0
                currentY += maxHeightInRow + spacing
                maxHeightInRow = 0
            }
            maxHeightInRow = max(maxHeightInRow, size.height)
            currentX += size.width + spacing
        }
        height = currentY + maxHeightInRow
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var maxHeightInRow: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX && currentX > bounds.minX {
                currentX = bounds.minX
                currentY += maxHeightInRow + spacing
                maxHeightInRow = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: ProposedViewSize(size))
            maxHeightInRow = max(maxHeightInRow, size.height)
            currentX += size.width + spacing
        }
    }
}

/// IDs and portrait filenames supplied by YU Torah's teacher catalog.
struct YUTorahRecommendedTeacher: Identifiable {
    let id: Int
    let name: String
    let photo: String

    static let all: [Self] = [
        .init(id: 80153, name: "Rabbi Hershel Schachter", photo: "hershel_schachter_o.jpg"),
        .init(id: 80146, name: "Rabbi Michael Rosensweig", photo: "michael_rosensweig_o.jpg"),
        .init(id: 80215, name: "Rabbi Mordechai Willig", photo: "mordechai_i._willig_o.jpg"),
        .init(id: 80182, name: "Rabbi Zvi Sobolofsky", photo: "zvi_sobolofsky_o.jpg"),
        .init(id: 80177, name: "Rabbi Eli Baruch Shulman", photo: "eliyahu_shulman_o.jpg")
    ]
}

struct YUTorahSourcePortrait: View {
    let teacherID: Int?
    var symbol = "person.fill"
    var size: CGFloat = 60
    @State private var resolvedURL: URL?

    private var portraitURL: URL? {
        if let teacher = YUTorahRecommendedTeacher.all.first(where: { $0.id == teacherID }) {
            return YUTorahPortraitLoader.imageURL(filename: teacher.photo)
        }
        return resolvedURL
    }

    var body: some View {
        AsyncImage(url: portraitURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [LecternTheme.accent.opacity(0.06), LecternTheme.accent.opacity(0.18)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.4, weight: .light))
                        .foregroundStyle(LecternTheme.accent)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .accessibilityHidden(true)
        .task(id: teacherID) {
            resolvedURL = nil
            guard let teacherID,
                  !YUTorahRecommendedTeacher.all.contains(where: { $0.id == teacherID }) else { return }
            let url = await YUTorahPortraitLoader.shared.portrait(for: teacherID)
            guard !Task.isCancelled else { return }
            resolvedURL = url
        }
    }
}

actor YUTorahPortraitLoader {
    static let shared = YUTorahPortraitLoader()
    private var cachedURLs: [Int: URL] = [:]
    private var requests: [Int: Task<URL?, Never>] = [:]

    nonisolated static func imageURL(filename: String) -> URL? {
        guard !filename.isEmpty, filename != "_default.jpg",
              !filename.contains("/"), !filename.contains("..") else { return nil }
        return URL(string: "https://cdnyutorah.cachefly.net/_images/roshei_yeshiva/")?
            .appendingPathComponent(filename)
    }

    func portrait(for teacherID: Int) async -> URL? {
        if let url = cachedURLs[teacherID] { return url }
        if let request = requests[teacherID] { return await request.value }
        let request = Task<URL?, Never> {
            guard let url = URL(string: "https://api.yutorah.org/search?teacherID=\(teacherID)&start=1") else { return nil }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                let result = try JSONDecoder().decode(PortraitResponse.self, from: data)
                guard let photo = result.response.docs.first(where: { $0.teacherid == teacherID })?.PHOTO else { return nil }
                return Self.imageURL(filename: photo)
            } catch {
                return nil
            }
        }
        requests[teacherID] = request
        let url = await request.value
        cachedURLs[teacherID] = url
        requests[teacherID] = nil
        return url
    }

    private struct PortraitResponse: Decodable {
        let response: Response
        struct Response: Decodable {
            let docs: [Document]
        }
        struct Document: Decodable {
            let teacherid: Int?
            let PHOTO: String?
        }
    }
}
