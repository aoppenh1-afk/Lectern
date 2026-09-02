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
    let onClose: () -> Void

    @State private var selectedLectureIDs: Set<PersistentIdentifier> = []
    @State private var selectedCanvasSourceLabels: Set<String> = []
    @State private var selectedAttachmentIDs: Set<PersistentIdentifier> = []
    @State private var selectedResourceKeys: Set<String> = []
    @State private var sourcesCollapsed = false
    @State private var sourcesManaging = false
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
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ScrollView {
                    if synthesis.turns.isEmpty && synthesis.response.isEmpty {
                        ContentUnavailableView(
                            "Ask across the course",
                            systemImage: "books.vertical",
                            description: Text("Compare lectures or build a study guide from the selected material.")
                        ).padding(.top, 60)
                    } else {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(synthesis.turns) { turn in
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack { Spacer(minLength: 80); Text(turn.question).font(.system(size: 12.5, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 10).background(LecternTheme.accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 16)) }
                                    HStack(alignment: .top, spacing: 12) {
                                        assistantBadge
                                        VStack(alignment: .leading, spacing: 8) {
                                            NotesContentView(markdown: turn.answer).padding(15).background(LecternTheme.cardFill, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(LecternTheme.hairline))
                                            sourceChips
                                        }
                                    }
                                }
                            }
                            if !synthesis.response.isEmpty {
                                HStack(alignment: .top, spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    NotesContentView(markdown: synthesis.response)
                                }
                            }
                        }
                        .padding(18)
                    }
                }
                if let error = synthesis.lastError {
                    Text(error).font(.system(size: 11)).foregroundStyle(.red).padding(.horizontal, 14)
                }
                Divider()
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
                .padding(12)
            }

            Divider()
            sourcesPanel
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
                    Text(sourcesManaging ? "Manage sources" : "Sources")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if sourcesManaging {
                        Button("None") { setAllSources(false) }
                            .buttonStyle(.plain).font(.system(size: 10.5)).foregroundStyle(.secondary)
                        Button("All") { setAllSources(true) }
                            .buttonStyle(.plain).font(.system(size: 10.5, weight: .medium))
                    } else {
                        Text("\(selectedSourceCount) selected")
                            .font(.system(size: 9.5)).foregroundStyle(.secondary)
                    }
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { sourcesCollapsed = true }
                    } label: {
                        Image(systemName: "sidebar.right")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("Collapse sources")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                Divider()

                if sourcesManaging {
                    sourceManager
                } else {
                    selectedSourcesSummary
                }

                Divider()

                if sourcesManaging {
                    HStack(spacing: 8) {
                        Button {
                            showingImporter = true
                        } label: {
                            Label("Add notes or slides", systemImage: "plus")
                                .frame(maxWidth: .infinity)
                        }
                        Button("Done") {
                            withAnimation(.easeInOut(duration: 0.18)) { sourcesManaging = false }
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .padding(14)
                } else {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { sourcesManaging = true }
                    } label: {
                        Text("Manage sources")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(LecternTheme.accent)
                            .frame(maxWidth: .infinity)
                            .frame(height: 34)
                    }
                    .buttonStyle(.plain)
                    .background(LecternTheme.cardFill, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(LecternTheme.hairline))
                    .padding(14)
                }
            }
            .frame(width: 340)
        }
    }

    private var selectedSourcesSummary: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if selectedSourceCount == 0 {
                    VStack(spacing: 8) {
                        Image(systemName: "books.vertical")
                            .font(.system(size: 24, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text("No sources selected")
                            .font(.system(size: 11.5, weight: .medium))
                        Text("Choose the lectures, files, and Canvas material this chat should use.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.top, 40)
                }

                if !selectedLectures.isEmpty {
                    sourceSummarySection(title: "Lectures", count: selectedLectures.count, isExpanded: $lecturesExpanded) {
                        ForEach(selectedLectures.sorted(by: { $0.capturedAt < $1.capturedAt })) { lecture in
                            sourceSummaryRow(
                                icon: "waveform",
                                title: lecture.title,
                                subtitle: "Recovered · \(lecture.capturedAt.formatted(date: .abbreviated, time: .shortened))"
                            )
                        }
                    }
                }

                if !selectedCanvasSummarySources.isEmpty {
                    sourceSummarySection(title: "Canvas resources", count: selectedCanvasSummarySources.count, isExpanded: $canvasExpanded) {
                        ForEach(selectedCanvasSummarySources, id: \.label) { source in
                            sourceSummaryRow(icon: "checkmark", title: source.label, subtitle: "Included")
                        }
                    }
                }

                if !selectedAttachments.isEmpty {
                    sourceSummarySection(title: "Course files", count: selectedAttachments.count, isExpanded: $attachmentsExpanded) {
                        ForEach(selectedAttachments) { attachment in
                            sourceSummaryRow(
                                icon: attachment.kind == .pdf ? "doc.richtext" : "doc.text",
                                title: attachment.name,
                                subtitle: "Included course file"
                            )
                        }
                    }
                }

                if !selectedResourceReferences.isEmpty {
                    sourceSummarySection(title: "Course resources", count: selectedResourceReferences.count, isExpanded: $resourcesExpanded) {
                        ForEach(courseCanvasResources.filter { selectedResourceKeys.contains($0.syncKey) }) { resource in
                            sourceSummaryRow(icon: "doc", title: resource.title, subtitle: resource.moduleName)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }

    private var sourceManager: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if !candidateLectures.isEmpty {
                    sourceSection(
                        title: "Lectures",
                        icon: "waveform",
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
                                Text(lecture.title).font(.system(size: 10.5)).lineLimit(2)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }

                if !canvasSources.isEmpty {
                    sourceSection(
                        title: "Canvas data",
                        icon: "building.columns",
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
                                Text(source.label).font(.system(size: 10.5)).lineLimit(2)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }

                if !course.attachments.isEmpty {
                    sourceSection(
                        title: "Course files",
                        icon: "paperclip",
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
                                Label(attachment.name, systemImage: attachment.kind == .pdf ? "doc.richtext" : "doc.text")
                                    .font(.system(size: 10.5)).lineLimit(2)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }

                if !courseCanvasResources.isEmpty {
                    sourceSection(
                        title: "Course resources",
                        icon: "folder",
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
            .padding(12)
        }
    }

    private func sourceSummarySection<Content: View>(title: String,
                                                      count: Int,
                                                      isExpanded: Binding<Bool>,
                                                      @ViewBuilder content: @escaping () -> Content) -> some View {
        DisclosureGroup(isExpanded: isExpanded) {
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.bottom, 12)
        } label: {
            HStack(spacing: 7) {
                Text(title).font(.system(size: 11.5, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.vertical, 12)
        }
        .overlay(alignment: .bottom) { Divider() }
    }

    private func sourceSummaryRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(LecternTheme.accent.opacity(0.10))
                .frame(width: 26, height: 26)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(LecternTheme.accent)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 10.75, weight: .medium))
                    .lineLimit(2)
                Text(subtitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
    }

    private func sourceSection<Content: View>(title: String,
                                              icon: String,
                                              selectedCount: Int,
                                              totalCount: Int,
                                              isExpanded: Binding<Bool>,
                                              @ViewBuilder content: @escaping () -> Content) -> some View {
        DisclosureGroup(isExpanded: isExpanded) {
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(.top, 8)
                .padding(.leading, 5)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LecternTheme.accent)
                    .frame(width: 18)
                Text(title).font(.system(size: 11.5, weight: .semibold))
                Spacer()
                Text("\(selectedCount)/\(totalCount)")
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(LecternTheme.hairline))
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
                        VStack(alignment: .leading, spacing: 2) {
                            Text(resource.title).font(.system(size: 10.5)).lineLimit(2)
                            Text(resource.kind).font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
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

    private var assistantBadge: some View {
        Circle().fill(LecternTheme.accent.opacity(0.12)).frame(width: 30, height: 30)
            .overlay(Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold)).foregroundStyle(LecternTheme.accent))
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
        if let modelID = effectiveModelID, AntigravityCLI.isThinkingVariant(modelID) {
            let next = AntigravityCLI.thinkingLevel(fromModelID: modelID).rawValue
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
        let next = AntigravityCLI.applyThinking(thinkingLevel, to: current, availableIDs: catalogIDs)
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

    var body: some View {
        VStack(spacing: 8) {
            TextField("Ask about this course…", text: $question, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .lineLimit(1...5)
                .onSubmit(submit)

            HStack(spacing: 10) {
                Button { modelPickerOpen.toggle() } label: {
                    HStack(spacing: 5) {
                        AgentProviderLogo(profileID: selectedProfile?.id ?? AgentProfiles.codexID)
                            .frame(width: 12, height: 12)
                        Text(modelLabel).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 8))
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
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
                    Button { thinkingPickerOpen.toggle() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "brain")
                            Text(thinkingLevel.title)
                            Image(systemName: "chevron.down").font(.system(size: 8))
                        }
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
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
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Button {
                    synthesis.isResponding ? synthesis.cancel() : submit()
                } label: {
                    Image(systemName: synthesis.isResponding ? "stop.fill" : "arrow.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(synthesis.isResponding ? LecternTheme.warningTint : LecternTheme.accent))
                }
                .buttonStyle(.plain)
                .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !synthesis.isResponding)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(LecternTheme.cardFill, in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(LecternTheme.hairline))
        .shadow(color: .black.opacity(0.035), radius: 10, y: 3)
    }

    private func submit() {
        onSend(question)
    }
}

private extension View {
    func sourceChip() -> some View {
        font(.system(size: 9.5)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.primary.opacity(0.035), in: Capsule()).overlay(Capsule().stroke(LecternTheme.hairline))
    }
}
