import AppKit
import SwiftData
import SwiftUI

struct MCPSettingsPane: View {
    @Environment(LecternCloudSharing.self) private var sharing
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Course.name) private var courses: [Course]
    @State private var confirmsDeletion = false
    @State private var search = ""
    @State private var selectedSemester = SemesterFilter.all
    @State private var showsAllCourses = false
    @State private var copiedURL = false

    private let green = Color(hex: "30583E")
    private let muted = Color.secondary

    private enum SemesterFilter: Hashable {
        case all
        case semester(String)
        case unassigned
    }

    private var availableSemesters: [String] {
        let terms = Set(courses.compactMap { course -> String? in
            guard let term = course.termName?.trimmingCharacters(in: .whitespaces), !term.isEmpty else {
                return nil
            }
            return term
        })
        return terms.sorted { lhs, rhs in
            let yearL = extractYear(from: lhs)
            let yearR = extractYear(from: rhs)
            if yearL != yearR {
                return yearL > yearR
            }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    private func extractYear(from term: String) -> Int {
        if let match = term.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression),
           let year = Int(term[match]) {
            return year
        }
        return 0
    }

    private var semesterOptions: [StudioDropdownOption<SemesterFilter>] {
        var options: [StudioDropdownOption<SemesterFilter>] = [
            StudioDropdownOption(value: .all, title: "All Semesters")
        ]
        for term in availableSemesters {
            options.append(StudioDropdownOption(value: .semester(term), title: term))
        }
        let hasUnassigned = courses.contains { ($0.termName ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        if hasUnassigned && !availableSemesters.isEmpty {
            options.append(StudioDropdownOption(value: .unassigned, title: "No Semester"))
        }
        return options
    }

    var body: some View {
        GeometryReader { geometry in
            page(wide: geometry.size.width >= 900, width: geometry.size.width)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pageHeight = $0 }
        }
        .frame(height: pageHeight)
        .foregroundStyle(LecternTheme.ink)
        .tint(green)
        .onAppear { try? modelContext.save() }
        .onChange(of: sharing.sharedCourseIDs) { _, _ in Task { await sharing.syncIfNeeded() } }
        .onChange(of: sharing.shareUnfiled) { _, _ in Task { await sharing.syncIfNeeded() } }
        .confirmationDialog("Delete the hosted library and revoke all connections?", isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button("Delete hosted library", role: .destructive) { Task { await sharing.deleteHostedLibrary() } }
        } message: {
            Text("ChatGPT, Claude and connected Macs will lose access. Lectern’s local notes and transcripts will be kept.")
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { paneWidth = $0 }
    }

    @State private var paneWidth: CGFloat = 1000
    @State private var pageHeight: CGFloat = 1000

    private func page(wide: Bool, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(wide: wide)
            if wide {
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 12) {
                        accountCard
                        coursesCard
                    }
                    .frame(width: (width - 14) * 0.61)
                    VStack(spacing: 12) {
                        syncCard
                        connectionCard
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                accountCard
                coursesCard
                syncCard
                connectionCard
            }
            deletionCard
        }
        .font(.system(size: 13.5))
    }

    private func header(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text("AI INTEGRATIONS")
                    .font(.system(size: 11.5, weight: .semibold)).tracking(1.4).foregroundStyle(muted)
                Text("ChatGPT & Claude")
                    .font(.custom("TimesNewRomanPS-BoldMT", size: wide ? 36 : 28))
                    .tracking(-1)
                Text("Share your lectures with ChatGPT and Claude through MCP. Your AI can read your courses, notes, and transcripts to help you study, generate insights, and answer questions — even when Lectern is closed.")
                    .font(.system(size: 13.5)).foregroundStyle(.secondary)
                    .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: wide ? 560 : .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .top, spacing: 16) {
                benefit("book.closed", title: "Your lectures, with your AI", text: "Ask questions, get summaries, and explore ideas.")
                benefit("lock", title: "Private & secure", text: "Only the content you choose is shared.")
                benefit("sparkles", title: "Works while away", text: "Your AI reads the synced copy even when closed.")
            }
            .frame(maxWidth: wide ? 760 : .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .topTrailing) {
            if wide {
                Image("MCPBanner").resizable().scaledToFit()
                    .frame(width: min(300, paneWidth * 0.30))
                    .mask {
                        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12), .init(color: .black, location: 0.88), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing)
                            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12), .init(color: .black, location: 0.85), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                    }
                    .opacity(0.7).offset(y: -10)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }

    private func benefit(_ icon: String, title: String, text: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(green)
                .frame(width: 26, height: 26)
                .background(green.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(text)
                    .foregroundStyle(muted)
                    .font(.system(size: 11.5))
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accountCard: some View {
        card {
            HStack(alignment: .top) {
                cardHeading("person", "Connected account", "Sign in with the same account you use in Lectern.")
                Spacer(minLength: 8)
                if sharing.auth.isSigningIn {
                    Button("Cancel sign-in") { sharing.auth.cancelSignIn() }.buttonStyle(MCPButtonStyle())
                } else if sharing.auth.isSignedIn {
                    Button("Disconnect") { sharing.disconnect() }
                        .buttonStyle(MCPButtonStyle()).disabled(sharing.isBusy)
                        .help("Disconnect this Mac. The hosted library and AI connections remain available.")
                } else {
                    Button("Sign in with Google") { Task { await sharing.signIn() } }
                        .buttonStyle(MCPButtonStyle()).disabled(sharing.isBusy)
                }
            }
            HStack(spacing: 10) {
                Text(sharing.auth.isSignedIn ? String((sharing.email ?? "L").prefix(1)).uppercased() : "L")
                    .font(.custom("Georgia", size: 14)).foregroundStyle(.white)
                    .frame(width: 30, height: 30).background(green.gradient, in: Circle())
                Text(sharing.auth.isSignedIn ? sharing.email ?? "Connected account" : "Sign in to share your lectures")
                    .font(.system(size: 13.5, weight: .medium)).textSelection(.enabled)
                if sharing.auth.isSignedIn {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(green)
                }
                Spacer(minLength: 0)
            }
            if let warning = sharing.auth.credentialWarning {
                Text(warning).font(.system(size: 12)).foregroundStyle(.orange)
            }
        }
    }

    private var filteredCourses: [Course] {
        courses.filter { course in
            let matchesSearch = search.isEmpty || course.name.localizedStandardContains(search)
            let matchesSemester: Bool
            switch selectedSemester {
            case .all:
                matchesSemester = true
            case .semester(let term):
                matchesSemester = AcademicScopeMatcher.matches(term: course.termName, selectedTerm: term)
            case .unassigned:
                matchesSemester = (course.termName ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            }
            return matchesSearch && matchesSemester
        }
    }
    private var visibleCourses: [Course] { showsAllCourses ? filteredCourses : Array(filteredCourses.prefix(6)) }
    private func isSelected(_ course: Course) -> Bool {
        guard let id = try? LecternCloudSharing.id(for: course.persistentModelID) else { return false }
        return sharing.sharedCourseIDs.contains(id)
    }

    private var coursesCard: some View {
        card {
            cardHeading("book", "Choose courses to share", "Select which courses your AI can access. Only course names, lecture titles, dates, notes and transcripts are shared.", smallCaption: true)
                .overlay(alignment: .topTrailing) {
                    Text("\(courses.filter { isSelected($0) }.count) of \(courses.count) selected")
                        .foregroundStyle(muted).font(.system(size: 12.5))
                }
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(muted)
                    TextField("Search courses...", text: $search)
                        .font(.system(size: 12.5))
                        .textFieldStyle(.plain)
                    if !search.isEmpty {
                        Button {
                            search = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(muted)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(LecternTheme.ink.opacity(0.025), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(LecternTheme.ink.opacity(0.07)))

                StudioDropdown(
                    title: "Semester",
                    selection: $selectedSemester,
                    options: semesterOptions,
                    width: 180
                )
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 5) {
                ForEach(visibleCourses) { course in courseRow(course) }
            }
            .disabled(sharing.isBusy)
            if filteredCourses.isEmpty {
                Text(courses.isEmpty ? "Your courses will appear here once you add them to Lectern." : "No courses match your filter.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(muted).padding(.vertical, 16).frame(maxWidth: .infinity)
            }
            if showsAllCourses {
                Toggle("Unfiled lectures", isOn: Binding(get: { sharing.shareUnfiled }, set: { sharing.shareUnfiled = $0 }))
                    .font(.system(size: 12.5))
                    .toggleStyle(.checkbox).disabled(sharing.isBusy)
            }
            if filteredCourses.count > 6 {
                Button {
                    showsAllCourses.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Text(showsAllCourses ? "Show fewer courses" : "Show all \(filteredCourses.count) courses")
                        Image(systemName: showsAllCourses ? "chevron.up" : "chevron.down")
                    }
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(green)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .help("Show all matching courses and the unfiled lectures option.")
            }
        }
    }

    private func courseRow(_ course: Course) -> some View {
        Button {
            guard let id = try? LecternCloudSharing.id(for: course.persistentModelID) else { return }
            if sharing.sharedCourseIDs.contains(id) { sharing.sharedCourseIDs.remove(id) }
            else { sharing.sharedCourseIDs.insert(id) }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: isSelected(course) ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15)).foregroundStyle(isSelected(course) ? green : Color.secondary.opacity(0.4))
                Image(systemName: "book.closed")
                    .font(.system(size: 13)).foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Color(hex: course.colorHex).gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(course.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    Text([course.termName, "\(course.lectures.count) lectures"].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11.5)).foregroundStyle(muted).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(LecternTheme.ink.opacity(0.025), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(course.name).accessibilityValue(isSelected(course) ? "Selected" : "Not selected")
        .help(course.name)
    }

    private var upToDate: Bool {
        sharing.auth.isSignedIn && sharing.sharingEnabled && !sharing.needsReview && sharing.status.hasPrefix("Shared library is up to date.")
    }
    private var syncCard: some View {
        card {
            cardHeading("arrow.triangle.2.circlepath", "Sync library", "Upload your latest lectures and keep your shared library up to date.")
            Button {
                Task {
                    if sharing.sharingEnabled && !sharing.needsReview { await sharing.syncIfNeeded() }
                    else { await sharing.startSharing() }
                }
            } label: {
                HStack {
                    if sharing.isBusy { ProgressView().controlSize(.small) }
                    Text(sharing.needsReview ? "Replace hosted selection" : sharing.sharingEnabled ? "Sync now" : "Start sharing")
                }.frame(maxWidth: .infinity)
            }.buttonStyle(MCPButtonStyle(prominent: true))
                .disabled(!sharing.auth.isSignedIn || sharing.isBusy)
            VStack(alignment: .leading, spacing: 2) {
                Text("Last successful sync").font(.system(size: 11))
                HStack(spacing: 6) {
                    Circle().fill(sharing.lastSync == nil ? Color.secondary : green).frame(width: 8, height: 8)
                    Text(sharing.lastSync?.formatted(date: .abbreviated, time: .shortened) ?? "Not synced yet")
                }.font(.system(size: 12.5))
            }.foregroundStyle(muted)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: upToDate ? "checkmark.circle.fill" : "info.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(green)
                VStack(alignment: .leading, spacing: 3) {
                    if upToDate {
                        Text("Shared library is up to date.")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(green)
                        Text("ChatGPT and Claude can read it while this Mac is closed.")
                            .font(.system(size: 12))
                            .foregroundStyle(muted)
                    } else {
                        Text(sharing.status)
                            .font(.system(size: 12.5))
                            .foregroundStyle(muted).textSelection(.enabled)
                    }
                    if sharing.needsReview {
                        Text("Replacing uses this Mac’s selection and replaces the current hosted library. Reconnect first if access was revoked.")
                            .font(.system(size: 12))
                            .foregroundStyle(muted)
                        Button("Reconnect account") { Task { await sharing.signIn() } }
                            .font(.system(size: 12.5))
                            .disabled(sharing.isBusy)
                    }
                }.fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(green.opacity(0.065), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }

    private var connectionCard: some View {
        card {
            cardHeading("link", "Connect your AI", "Add this server URL in ChatGPT or Claude.")
            HStack(spacing: 8) {
                Text(LecternCloudSharing.connectionURL.absoluteString)
                    .font(.system(size: 12, weight: .medium, design: .monospaced)).textSelection(.enabled)
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LecternTheme.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Button {
                    NSPasteboard.general.clearContents()
                    copiedURL = NSPasteboard.general.setString(LecternCloudSharing.connectionURL.absoluteString, forType: .string)
                } label: { Image(systemName: copiedURL ? "checkmark" : "doc.on.doc").font(.system(size: 15)) }
                    .buttonStyle(MCPButtonStyle()).help(copiedURL ? "Copied URL" : "Copy URL")
                    .accessibilityLabel(copiedURL ? "Copied URL" : "Copy URL")
            }
            Text("ChatGPT: enable developer mode and add an MCP connection with OAuth. Claude: add a custom connector. Sign in with the same Google account, approve read access, and enable Lectern in the conversation.")
                .font(.system(size: 12)).foregroundStyle(muted).lineSpacing(1.5).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                setupLink("Manage connections", url: LecternCloudAuth.origin.appendingPathComponent("connect"))
                setupLink("ChatGPT setup", url: URL(string: "https://developers.openai.com/plugins/deploy/connect-chatgpt")!)
                setupLink("Claude setup", url: URL(string: "https://support.claude.com/en/articles/11175166-get-started-with-custom-connectors-using-remote-mcp")!)
            }
        }
    }

    private var deletionCard: some View {
        card {
            HStack(spacing: 12) {
                iconBadge("trash", destructive: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Delete hosted library and disconnect all apps")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Removing your hosted copy keeps your local library. Copies already read by an AI service may remain with that service.")
                        .font(.system(size: 11.5)).foregroundStyle(muted)
                }
                Spacer(minLength: 12)
                Button("Delete and disconnect", role: .destructive) { confirmsDeletion = true }
                    .buttonStyle(MCPButtonStyle(destructive: true))
                    .disabled(!sharing.auth.isSignedIn || sharing.isBusy)
            }
        }
    }

    private func setupLink(_ title: String, url: URL) -> some View {
        Link(destination: url) { HStack(spacing: 4) { Text(title); Image(systemName: "arrow.right").font(.system(size: 9)) } }
            .font(.system(size: 12, weight: .medium)).foregroundStyle(green)
    }
    private func iconBadge(_ icon: String, destructive: Bool = false) -> some View {
        Image(systemName: icon).font(.system(size: 15, weight: .medium))
            .foregroundStyle(destructive ? Color(hex: "AF342C") : green)
            .frame(width: 30, height: 30)
            .background((destructive ? Color.red : green).opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    private func cardHeading(_ icon: String, _ title: String, _ caption: String, smallCaption: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            iconBadge(icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.custom("TimesNewRomanPS-BoldMT", size: 17.5))
                Text(caption).font(.system(size: smallCaption ? 11.5 : 12)).foregroundStyle(muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 11, content: content)
            .padding(13).frame(maxWidth: .infinity, alignment: .leading)
            .background(LecternTheme.canvasCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(LecternTheme.ink.opacity(0.065)))
            .shadow(color: .black.opacity(0.02), radius: 6, y: 1)
    }
}

private struct MCPButtonStyle: ButtonStyle {
    var prominent = false
    var destructive = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12.5, weight: .semibold))
            .padding(.horizontal, 13).padding(.vertical, 7)
            .foregroundStyle(prominent ? .white : destructive ? Color(hex: "AF342C") : LecternTheme.ink)
            .background(prominent ? Color(hex: "30583E") : destructive ? Color.red.opacity(0.12) : LecternTheme.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
    }
}
