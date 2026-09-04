import SwiftUI
import SwiftData

struct CourseSynthesisView: View {
    private struct ResourceModuleGroup: Identifiable {
        let id: String
        let name: String
        let resources: [CanvasResource]
    }

    @Environment(CourseSynthesisService.self) private var synthesis
    @Environment(CanvasConnectionSettings.self) private var canvasConnection
    @Environment(\.modelContext) private var modelContext
    @Query private var canvasAssignments: [CanvasAssignment]
    @Query private var canvasEvents: [CanvasEvent]
    @Query private var canvasResources: [CanvasResource]
    @Query private var canvasAnnouncements: [CanvasAnnouncement]
    @Query(sort: \Lecture.capturedAt, order: .reverse) private var allLectures: [Lecture]
    @Bindable var course: Course
    let availableCourses: [Course]
    @Binding var selectedCourseID: PersistentIdentifier?
    let onClose: () -> Void

    init(
        course: Course,
        availableCourses: [Course] = [],
        selectedCourseID: Binding<PersistentIdentifier?>,
        onClose: @escaping () -> Void
    ) {
        self.course = course
        self.availableCourses = availableCourses
        self._selectedCourseID = selectedCourseID
        self.onClose = onClose
    }

    @State private var selectedLectureIDs: Set<PersistentIdentifier> = []
    @State private var selectedCanvasSourceLabels: Set<String> = []
    @State private var selectedAttachmentIDs: Set<PersistentIdentifier> = []
    @State private var selectedResourceKeys: Set<String> = []
    @State private var sourcesCollapsed = false
    @State private var lecturesExpanded = true
    @State private var canvasExpanded = true
    @State private var attachmentsExpanded = true
    @State private var resourcesExpanded = true
    @State private var expandedResourceModules: Set<String> = []
    @AppStorage("generation.agentID") private var profileID = AgentProfiles.codexID
    @AppStorage("generation.thinkingLevel") private var thinkingLevelRaw = ThinkingLevel.medium.rawValue
    @State private var modelOverride: String?
    @State private var modelCatalogs: [String: AgentModelCatalog] = [:]
    @State private var modelCatalogsLoading = false
    @State private var modelPickerOpen = false
    @State private var thinkingPickerOpen = false
    @State private var showingImporter = false
    @State private var importError: String?

    private var selectedLectures: [Lecture] {
        candidateLectures.filter { selectedLectureIDs.contains($0.persistentModelID) }
    }

    private var selectedCanvasSummarySources: [CourseChatCanvasSource] {
        canvasSources.filter { selectedCanvasSourceLabels.contains($0.label) }
    }

    private var selectedResourceReferences: [CanvasResourceReference] {
        courseCanvasResources
            .filter { selectedResourceKeys.contains($0.syncKey) }
            .map { resource in
                CanvasResourceReference(
                    title: resource.title,
                    moduleName: resource.moduleName,
                    kind: resource.kind,
                    canvasID: resource.canvasID,
                    htmlURL: resource.htmlURL,
                    apiURL: resource.apiURL
                )
            }
    }

    private var selectedCanvasSources: [CourseChatCanvasSource] {
        selectedCanvasSummarySources
    }

    private var selectedAttachments: [ReferenceAttachment] {
        course.attachments.filter { selectedAttachmentIDs.contains($0.persistentModelID) }
    }

    private var candidateLectures: [Lecture] {
        allLectures.filter { $0.course == course || $0.isUnfiled }
    }

    private var courseCanvasResources: [CanvasResource] {
        guard let courseID = course.canvasID else { return [] }
        return canvasResources
            .filter { $0.courseCanvasID == courseID }
            .sorted {
                ($0.moduleName, $0.position, $0.title) < ($1.moduleName, $1.position, $1.title)
            }
    }

    private var resourceModuleGroups: [ResourceModuleGroup] {
        Dictionary(grouping: courseCanvasResources, by: \.moduleName)
            .map { name, resources in
                ResourceModuleGroup(id: name, name: name, resources: resources)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var selectedSourceCount: Int {
        selectedLectures.count + selectedAttachments.count + selectedCanvasSources.count + selectedResourceReferences.count
    }

    private var profiles: [AgentProfile] { AgentProfiles.all() }
    private var selectedProfile: AgentProfile? { profiles.first { $0.id == profileID } ?? profiles.first }
    private var thinkingLevel: ThinkingLevel { ThinkingLevel(rawValue: thinkingLevelRaw) ?? .medium }
    private var effectiveModelID: String? { modelOverride ?? selectedProfile?.model }
    private var selectedModel: AgentModel? {
        guard let profile = selectedProfile, let catalog = modelCatalogs[profile.id] else { return nil }
        if let effectiveModelID, let exact = catalog.models.first(where: { $0.id == effectiveModelID }) { return exact }
        if let currentID = catalog.currentID, let current = catalog.models.first(where: { $0.id == currentID }) { return current }
        return catalog.models.first(where: \.isDefault) ?? catalog.models.first
    }
    private var thinkingLevels: [ThinkingLevel] {
        ThinkingLevel.chatOptions(profileID: selectedProfile?.id, advertised: selectedModel?.supportedThinkingLevels ?? [])
    }
    private var modelLabel: String {
        guard let profile = selectedProfile else { return "Choose agent" }
        guard let modelID = effectiveModelID, !modelID.isEmpty else { return "\(profile.title) default" }
        return modelCatalogs[profile.id]?.models.first(where: { $0.id == modelID })?.name ?? modelID
    }

    private var canvasSources: [CourseChatCanvasSource] {
        guard let courseID = course.canvasID else { return [] }
        var sources: [CourseChatCanvasSource] = []
        if let syllabus = course.syllabusHTML?.canvasPlainText, !syllabus.isEmpty {
            sources.append(.init(label: "Canvas syllabus", content: syllabus))
        }

        let assignments = canvasAssignments
            .filter { $0.courseCanvasID == courseID }
            .sorted { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
        if !assignments.isEmpty {
            let content = assignments.map { assignment in
                let due = assignment.dueAt?.formatted(date: .abbreviated, time: .shortened) ?? "No due date"
                let status = assignment.grade ?? assignment.submissionState ?? "not submitted"
                return "- \(assignment.title) — due \(due); status: \(status); points: \(assignment.pointsPossible?.formatted() ?? "unknown")"
            }.joined(separator: "\n")
            sources.append(.init(label: "Canvas assignments and grades", content: content))
        }

        let events = canvasEvents.filter { $0.courseCanvasID == courseID }.sorted { $0.startAt < $1.startAt }
        if !events.isEmpty {
            sources.append(.init(label: "Canvas calendar", content: events.map {
                "- \($0.title) — \($0.startAt.formatted(date: .abbreviated, time: .shortened))\($0.locationName.map { "; location: \($0)" } ?? "")"
            }.joined(separator: "\n")))
        }

        let announcements = canvasAnnouncements.filter { $0.courseCanvasID == courseID }.sorted { $0.postedAt > $1.postedAt }
        if !announcements.isEmpty {
            sources.append(.init(label: "Canvas announcements", content: announcements.map {
                "## \($0.title)\n\($0.messageHTML?.canvasPlainText ?? "")"
            }.joined(separator: "\n\n")))
        }

        return sources
    }

    var body: some View {
        VStack(spacing: 0) {
            chatHeader

            HStack(spacing: 20) {
                conversationColumn
                sourcesPanel
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .onAppear {
            selectedLectureIDs = Set(course.lectures.map(\.persistentModelID))
            selectedCanvasSourceLabels = Set(canvasSources.map(\.label))
            selectedAttachmentIDs = Set(course.attachments.map(\.persistentModelID))
        }
        .onChange(of: course.attachments.count) { _, _ in
            selectedAttachmentIDs.formUnion(course.attachments.map(\.persistentModelID))
        }
        .onChange(of: courseCanvasResources.count) { _, _ in
            selectedResourceKeys.formIntersection(Set(courseCanvasResources.map(\.syncKey)))
        }
        .task {
            if modelOverride == nil { modelOverride = selectedProfile?.model }
            await loadModelCatalogs()
            normalizeThinkingLevel()
        }
        .onChange(of: effectiveModelID) { _, _ in normalizeThinkingLevel() }
        .onChange(of: thinkingLevelRaw) { _, _ in applyThinkingToSelectedModel() }
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.data],
                      allowsMultipleSelection: true) { result in
            do {
                try ReferenceMaterialService.importFiles(try result.get(), course: course, lecture: nil, context: modelContext)
            } catch { importError = error.localizedDescription }
        }
        .alert("Attachment Import Failed", isPresented: .init(
            get: { importError != nil }, set: { if !$0 { importError = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(importError ?? "") }
    }

    private var conversationColumn: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        if synthesis.turns.isEmpty && !synthesis.isResponding && synthesis.pendingQuestion == nil {
                            greetingCard
                                .padding(.top, 24)
                        } else {
                            VStack(alignment: .leading, spacing: 16) {
                                ForEach(synthesis.turns) { turn in
                                    VStack(alignment: .leading, spacing: 10) {
                                        HStack { Spacer(minLength: 80); Text(turn.question).font(.system(size: 12.5, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 10).background(LecternTheme.chatUserBubble, in: RoundedRectangle(cornerRadius: 16)) }
                                        HStack(alignment: .top, spacing: 12) {
                                            assistantBadge
                                            VStack(alignment: .leading, spacing: 8) {
                                                NotesContentView(markdown: turn.answer).padding(15).elevatedCard()
                                                sourceChips
                                            }
                                        }
                                    }
                                    .id(turn.id)
                                }
                                if let pending = synthesis.pendingQuestion {
                                    HStack { Spacer(minLength: 80); Text(pending).font(.system(size: 12.5, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 10).background(LecternTheme.chatUserBubble, in: RoundedRectangle(cornerRadius: 16)) }
                                        .id("pending-question")
                                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                                }
                                if synthesis.isResponding {
                                    HStack(alignment: .top, spacing: 12) {
                                        assistantBadge
                                        if synthesis.response.isEmpty {
                                            TypingIndicatorView()
                                                .padding(15)
                                                .elevatedCard()
                                        } else {
                                            VStack(alignment: .leading, spacing: 10) {
                                                NotesContentView(markdown: synthesis.response)
                                                    .padding(15)
                                                    .elevatedCard()
                                                TypingIndicatorView(dotDiameter: 6)
                                                    .padding(.leading, 8)
                                            }
                                        }
                                    }
                                    .id("course-typing")
                                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                                }
                            }
                            .padding(.vertical, 18)
                        }
                    }
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: synthesis.turns.count) { _, _ in
                    withAnimation(LecternTheme.standardAnimation) {
                        if let last = synthesis.turns.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: synthesis.pendingQuestion) { _, _ in
                    withAnimation(LecternTheme.standardAnimation) {
                        if synthesis.pendingQuestion != nil {
                            proxy.scrollTo("pending-question", anchor: .bottom)
                        } else {
                            proxy.scrollTo("course-typing", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: synthesis.response) { _, _ in
                    proxy.scrollTo("course-typing", anchor: .bottom)
                }
            }

            if let error = synthesis.lastError {
                Text(error).font(.system(size: 11)).foregroundStyle(.red).padding(.horizontal, 14)
            }

            CourseSynthesisComposer(
                profiles: profiles,
                selectedProfile: selectedProfile,
                modelCatalogs: modelCatalogs,
                modelCatalogsLoading: modelCatalogsLoading,
                modelLabel: modelLabel,
                thinkingLevels: thinkingLevels,
                defaultThinkingLevel: selectedModel?.defaultThinkingLevel,
                profileID: $profileID,
                modelOverride: $modelOverride,
                thinkingLevelRaw: $thinkingLevelRaw,
                modelPickerOpen: $modelPickerOpen,
                thinkingPickerOpen: $thinkingPickerOpen,
                onSend: send
            )
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var sourcesPanel: some View {
        if sourcesCollapsed {
            VStack(spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { sourcesCollapsed = false }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .help("Show sources")

                Text("\(selectedSourceCount)")
                    .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(LecternTheme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(LecternTheme.accent.opacity(0.10), in: Capsule())
                Spacer()
            }
            .padding(.vertical, 12)
            .frame(width: 46)
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("Sources")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Menu {
                        Button("Select all sources") { setAllSources(true) }
                        Button("Clear selection") { setAllSources(false) }
                    } label: {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 28, height: 28)
                            .background(LecternTheme.canvasCard, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(LecternTheme.hairline))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()

                    Text("\(selectedSourceCount) selected")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { sourcesCollapsed = true }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("Collapse sources")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                Divider()

                sourceManager

                Button {
                    showingImporter = true
                } label: {
                    Label("Add notes or slides", systemImage: "plus")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(LecternTheme.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                }
                .buttonStyle(.plain)
                .background(LecternTheme.canvasCard, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(LecternTheme.hairline))
                .shadow(color: Color.black.opacity(0.05), radius: 8, y: 2)
                .padding(14)
            }
            .panelCard(cornerRadius: 16)
            .frame(width: 360)
        }
    }

    private var sourceManager: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if hasNoSources {
                    VStack(spacing: 8) {
                        Image(systemName: "books.vertical")
                            .font(.system(size: 24, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text("No sources yet")
                            .font(.system(size: 11.5, weight: .medium))
                        Text("Add notes or slides below, or sync Canvas material to give this chat something to use.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 40)
                }

                if !candidateLectures.isEmpty {
                    sourceSection(
                        title: "Lectures",
                        selectedCount: selectedLectures.count,
                        totalCount: candidateLectures.count,
                        isExpanded: $lecturesExpanded
                    ) {
                        ForEach(candidateLectures.sorted(by: { $0.capturedAt < $1.capturedAt })) { lecture in
                            Toggle(isOn: Binding(
                                get: { selectedLectureIDs.contains(lecture.persistentModelID) },
                                set: { selected in
                                    if selected { selectedLectureIDs.insert(lecture.persistentModelID) }
                                    else { selectedLectureIDs.remove(lecture.persistentModelID) }
                                }
                            )) {
                                HStack(spacing: 9) {
                                    SourceRowIcon(icon: "doc.text", tint: .blue)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(lecture.title).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                                        Text("Recovered · \(lecture.capturedAt.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                            .toggleStyle(CircleCheckToggleStyle())
                        }
                    }
                }

                if !canvasSources.isEmpty {
                    sourceSection(
                        title: "Canvas data",
                        selectedCount: selectedCanvasSummarySources.count,
                        totalCount: canvasSources.count,
                        isExpanded: $canvasExpanded
                    ) {
                        ForEach(canvasSources, id: \.label) { source in
                            Toggle(isOn: Binding(
                                get: { selectedCanvasSourceLabels.contains(source.label) },
                                set: { selected in
                                    if selected { selectedCanvasSourceLabels.insert(source.label) }
                                    else { selectedCanvasSourceLabels.remove(source.label) }
                                }
                            )) {
                                HStack(spacing: 9) {
                                    SourceRowIcon(icon: "building.columns", tint: .blue)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(source.label).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                                        Text(selectedCanvasSourceLabels.contains(source.label) ? "Included" : "Not included")
                                            .font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                            .toggleStyle(CircleCheckToggleStyle())
                        }
                    }
                }

                if !course.attachments.isEmpty {
                    sourceSection(
                        title: "Course files",
                        selectedCount: selectedAttachments.count,
                        totalCount: course.attachments.count,
                        isExpanded: $attachmentsExpanded
                    ) {
                        ForEach(course.attachments) { attachment in
                            Toggle(isOn: Binding(
                                get: { selectedAttachmentIDs.contains(attachment.persistentModelID) },
                                set: { selected in
                                    if selected { selectedAttachmentIDs.insert(attachment.persistentModelID) }
                                    else { selectedAttachmentIDs.remove(attachment.persistentModelID) }
                                }
                            )) {
                                HStack(spacing: 9) {
                                    SourceRowIcon(
                                        icon: attachmentRowIcon(for: attachment.kind),
                                        tint: attachmentRowTint(for: attachment.kind)
                                    )
                                    Text(attachment.name)
                                        .font(.system(size: 11.5)).lineLimit(2)
                                }
                            }
                            .toggleStyle(CircleCheckToggleStyle())
                        }
                    }
                }

                if !courseCanvasResources.isEmpty {
                    sourceSection(
                        title: "Course resources",
                        selectedCount: selectedResourceKeys.count,
                        totalCount: courseCanvasResources.count,
                        isExpanded: $resourcesExpanded
                    ) {
                        HStack {
                            Text("\(resourceModuleGroups.count) modules")
                                .font(.system(size: 9.5)).foregroundStyle(.secondary)
                            Spacer()
                            Button("None") { selectedResourceKeys.removeAll() }
                                .buttonStyle(.plain).font(.system(size: 9.5)).foregroundStyle(.secondary)
                            Button("All") { selectedResourceKeys = Set(courseCanvasResources.map(\.syncKey)) }
                                .buttonStyle(.plain).font(.system(size: 9.5, weight: .medium))
                        }
                        ForEach(resourceModuleGroups) { group in resourceModuleSection(group) }
                    }
                }
            }
        }
    }

    private var hasNoSources: Bool {
        candidateLectures.isEmpty
            && canvasSources.isEmpty
            && course.attachments.isEmpty
            && courseCanvasResources.isEmpty
    }

    private func sourceSection<Content: View>(title: String,
                                              selectedCount: Int,
                                              totalCount: Int,
                                              isExpanded: Binding<Bool>,
                                              @ViewBuilder content: @escaping () -> Content) -> some View {
        VStack(spacing: 0) {
            DisclosureGroup(isExpanded: isExpanded) {
                VStack(alignment: .leading, spacing: 10) { content() }
                    .padding(.top, 10)
            } label: {
                HStack(spacing: 7) {
                    Text(title).font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    Text("\(selectedCount)/\(totalCount)")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
            }
            .tint(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            Divider()
        }
    }

    private func attachmentRowIcon(for kind: ReferenceAttachmentKind) -> String {
        switch kind {
        case .pdf, .word: return "doc.richtext"
        case .markdown, .text: return "doc.text"
        }
    }

    private func attachmentRowTint(for kind: ReferenceAttachmentKind) -> Color {
        switch kind {
        case .pdf: return .red
        case .word, .markdown, .text: return .blue
        }
    }

    private func resourceModuleSection(_ group: ResourceModuleGroup) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expandedResourceModules.contains(group.id) },
            set: { expanded in
                if expanded { expandedResourceModules.insert(group.id) }
                else { expandedResourceModules.remove(group.id) }
            }
        )) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(group.resources) { resource in
                    Toggle(isOn: Binding(
                        get: { selectedResourceKeys.contains(resource.syncKey) },
                        set: { selected in
                            if selected { selectedResourceKeys.insert(resource.syncKey) }
                            else { selectedResourceKeys.remove(resource.syncKey) }
                        }
                    )) {
                        HStack(spacing: 9) {
                            SourceRowIcon(
                                icon: resource.kind.lowercased().contains("pdf") ? "doc.richtext" : "doc.text",
                                tint: resource.kind.lowercased().contains("pdf") ? .red : .blue
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(resource.title).font(.system(size: 11.5)).lineLimit(2)
                                Text(resource.kind).font(.system(size: 9.5)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(CircleCheckToggleStyle())
                }
            }
            .padding(.top, 7)
            .padding(.leading, 5)
        } label: {
            HStack(spacing: 6) {
                Text(group.name).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                Spacer()
                Text("\(group.resources.lazy.filter { selectedResourceKeys.contains($0.syncKey) }.count)/\(group.resources.count)")
                    .font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func setAllSources(_ selected: Bool) {
        if selected {
            selectedLectureIDs = Set(candidateLectures.map(\.persistentModelID))
            selectedCanvasSourceLabels = Set(canvasSources.map(\.label))
            selectedAttachmentIDs = Set(course.attachments.map(\.persistentModelID))
            selectedResourceKeys = Set(courseCanvasResources.map(\.syncKey))
        } else {
            selectedLectureIDs.removeAll()
            selectedCanvasSourceLabels.removeAll()
            selectedAttachmentIDs.removeAll()
            selectedResourceKeys.removeAll()
        }
    }

    private func send(_ question: String) {
        guard let profile = selectedProfile else { return }
        let credentials = try? canvasConnection.credentials()
        withAnimation(LecternTheme.standardAnimation) {
            synthesis.send(question,
                           course: course,
                           lectures: selectedLectures,
                           canvasSources: selectedCanvasSources,
                           canvasResources: selectedResourceReferences,
                           canvasCredentials: credentials,
                           attachments: selectedAttachments,
                           profile: profile,
                           thinkingLevel: thinkingLevel,
                           modelOverride: effectiveModelID)
        }
    }

    private var chatHeader: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(LecternTheme.canvasCard)
                .frame(width: 34, height: 34)
                .overlay(Circle().strokeBorder(LecternTheme.hairline, lineWidth: 1))
                .overlay(
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LecternTheme.accent)
                )
                .shadow(color: Color.black.opacity(0.05), radius: 5, y: 1)
            VStack(alignment: .leading, spacing: 1) {
                Text("AI Assistant")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LecternTheme.accent)
                Text("Ask across lectures and course files.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !courseOptions.isEmpty {
                StudioDropdown(
                    title: "Course",
                    selection: Binding(
                        get: { selectedCourseID ?? course.persistentModelID },
                        set: { selectedCourseID = $0 }
                    ),
                    options: courseOptions,
                    width: 300,
                    icon: "book.closed"
                )
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 22)
    }

    private var courseOptions: [StudioDropdownOption<PersistentIdentifier?>] {
        availableCourses.map { course in
            StudioDropdownOption(value: Optional(course.persistentModelID), title: course.name, subtitle: course.courseCode)
        }
    }

    private var assistantBadge: some View {
        Circle()
            .fill(LecternTheme.canvasCard)
            .frame(width: 30, height: 30)
            .overlay(Circle().strokeBorder(LecternTheme.hairline, lineWidth: 1))
            .overlay(Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold)).foregroundStyle(LecternTheme.accent))
            .shadow(color: Color.black.opacity(0.05), radius: 5, y: 1)
    }

    private var greetingCard: some View {
        HStack(alignment: .top, spacing: 12) {
            assistantBadge
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 10) {
                (Text("Hello! I am your study assistant for ") + Text(course.name).bold() + Text(". How can I help you today?"))
                    .font(.system(size: 13))
                    .foregroundStyle(LecternTheme.ink)
                Text("Ask me anything about your lectures, notes, or Canvas material.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                if selectedSourceCount > 0 {
                    sourceChips
                }
            }
            .lineSpacing(4)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .elevatedCard()
        }
    }

    private var sourceChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(selectedLectures, id: \.persistentModelID) { lecture in Label(lecture.title, systemImage: "waveform").lineLimit(1).sourceChip() }
                ForEach(selectedAttachments) { attachment in Label(attachment.name, systemImage: "paperclip").lineLimit(1).sourceChip() }
                ForEach(selectedCanvasSummarySources, id: \.label) { source in Label(source.label, systemImage: "building.columns").lineLimit(1).sourceChip() }
                ForEach(courseCanvasResources.filter { selectedResourceKeys.contains($0.syncKey) }) { resource in
                    Label(resource.title, systemImage: "doc").lineLimit(1).sourceChip()
                }
            }
        }
    }

    private func normalizeThinkingLevel() {
        if let modelID = effectiveModelID, AntigravityACPClient.isThinkingVariant(modelID) {
            let next = AntigravityACPClient.thinkingLevel(fromModelID: modelID).rawValue
            if thinkingLevelRaw != next {
                thinkingLevelRaw = next
            }
            return
        }
        guard !thinkingLevels.isEmpty, !thinkingLevels.contains(thinkingLevel) else { return }
        thinkingLevelRaw = (selectedModel?.defaultThinkingLevel ?? thinkingLevels[0]).rawValue
    }

    private func applyThinkingToSelectedModel() {
        guard selectedProfile?.id == AgentProfiles.antigravityID,
              let current = effectiveModelID else { return }
        let catalogIDs = modelCatalogs[AgentProfiles.antigravityID]?.models.map(\.id) ?? []
        let next = AntigravityACPClient.applyThinking(thinkingLevel, to: current, availableIDs: catalogIDs)
        guard next != current else { return }
        modelOverride = next
        AgentProfiles.setModel(next, for: AgentProfiles.antigravityID)
    }

    private func loadModelCatalogs() async {
        guard !modelCatalogsLoading, modelCatalogs.isEmpty else { return }
        modelCatalogsLoading = true
        var loaded: [String: AgentModelCatalog] = [:]
        for profile in profiles { loaded[profile.id] = await AgentModelCatalogLoader.load(for: profile) }
        modelCatalogs = loaded
        modelCatalogsLoading = false
    }
}

private struct CourseSynthesisComposer: View {
    @Environment(CourseSynthesisService.self) private var synthesis
    @State private var question = ""
    @FocusState private var composerFocused: Bool

    let profiles: [AgentProfile]
    let selectedProfile: AgentProfile?
    let modelCatalogs: [String: AgentModelCatalog]
    let modelCatalogsLoading: Bool
    let modelLabel: String
    let thinkingLevels: [ThinkingLevel]
    let defaultThinkingLevel: ThinkingLevel?
    @Binding var profileID: String
    @Binding var modelOverride: String?
    @Binding var thinkingLevelRaw: String
    @Binding var modelPickerOpen: Bool
    @Binding var thinkingPickerOpen: Bool
    let onSend: (String) -> Void

    private var thinkingLevel: ThinkingLevel {
        ThinkingLevel(rawValue: thinkingLevelRaw) ?? .medium
    }

    private var shortModelLabel: String {
        thinkingLevels.isEmpty ? modelLabel : ComposerShortModelLabel(modelLabel)
    }

    private var questionIsEmpty: Bool {
        question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Ask about this course…", text: $question, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(1...6)
                .focused($composerFocused)
                .onSubmit(submit)
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 10)

            HStack(spacing: 6) {
                ComposerMenuButton {
                    modelPickerOpen.toggle()
                } content: {
                    AgentProviderLogo(profileID: selectedProfile?.id ?? AgentProfiles.codexID)
                        .frame(width: 14, height: 14)
                    Text(shortModelLabel)
                        .lineLimit(1)
                }
                .fixedSize()
                .popover(isPresented: $modelPickerOpen, arrowEdge: .bottom) {
                    LectureModelPicker(
                        profiles: profiles,
                        catalogs: modelCatalogs,
                        isLoading: modelCatalogsLoading,
                        isPresented: $modelPickerOpen,
                        selectedProfileID: $profileID,
                        selectedModelID: $modelOverride
                    )
                }

                if !thinkingLevels.isEmpty {
                    ComposerDivider()

                    ComposerMenuButton {
                        thinkingPickerOpen.toggle()
                    } content: {
                        Image(systemName: "brain")
                            .font(.system(size: 12))
                        Text(thinkingLevel.title)
                    }
                    .popover(isPresented: $thinkingPickerOpen, arrowEdge: .bottom) {
                        ThinkingLevelPicker(
                            levels: thinkingLevels,
                            defaultLevel: defaultThinkingLevel,
                            selection: $thinkingLevelRaw,
                            isPresented: $thinkingPickerOpen
                        )
                    }
                }

                Spacer()

                if !synthesis.turns.isEmpty {
                    Button("Clear") { synthesis.clear() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 4)
                }

                ComposerSendButton(
                    canSend: !questionIsEmpty,
                    isResponding: synthesis.isResponding,
                    send: submit,
                    cancel: { synthesis.cancel() }
                )
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .composerContainer(focused: composerFocused)
    }

    private func submit() {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !synthesis.isResponding else { return }
        question = ""
        onSend(trimmed)
    }
}

private extension View {
    func sourceChip() -> some View {
        font(.system(size: 9.5)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 4)
            .background(LecternTheme.canvasCard, in: Capsule()).overlay(Capsule().stroke(LecternTheme.hairline))
    }
}
