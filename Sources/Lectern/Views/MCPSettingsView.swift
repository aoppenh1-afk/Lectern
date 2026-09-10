import AppKit
import SwiftData
import SwiftUI

struct MCPSettingsPane: View {
    @Environment(LecternCloudSharing.self) private var sharing
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Course.name) private var courses: [Course]
    @State private var confirmsDeletion = false
    @State private var search = ""
    @State private var filter = CourseFilter.all
    @State private var showsAllCourses = false
    @State private var copiedURL = false

    private let green = Color(hex: "30583E")
    private let muted = Color.secondary
    private enum CourseFilter: String, CaseIterable {
        case all = "All Courses", selected = "Selected", unselected = "Not Selected"
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
        VStack(alignment: .leading, spacing: 18) {
            header(wide: wide)
            if wide {
                HStack(alignment: .top, spacing: 18) {
                    VStack(spacing: 18) {
                        accountCard
                        coursesCard
                    }
                    .frame(width: (width - 18) * 0.625)
                    VStack(spacing: 18) {
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
        .font(.system(size: 14))
    }

    private func header(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Text("AI INTEGRATIONS")
                    .font(.system(size: 12, weight: .semibold)).tracking(1.5).foregroundStyle(muted)
                Text("ChatGPT & Claude")
                    .font(.custom("TimesNewRomanPS-BoldMT", size: wide ? 60 : 44))
                    .tracking(-2)
                Text("Share your lectures with ChatGPT and Claude through MCP. Your AI can read your courses, notes, and transcripts to help you study, generate insights, and answer questions — even when Lectern is closed.")
                    .font(.system(size: 16)).foregroundStyle(.secondary)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: wide ? 635 : .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .top, spacing: 26) {
                benefit("book.closed", title: "Your lectures,\nwith your AI", text: "Ask questions, get summaries,\nand explore ideas.")
                benefit("lock", title: "Private & secure", text: "Only the content you choose\nis shared. You stay in control.")
                benefit("sparkles", title: "Works while you’re away", text: "Your AI can read the last synced\ncopy even when Lectern isn’t\nrunning.")
            }
            .frame(maxWidth: wide ? 820 : .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .topTrailing) {
            if wide {
                Image("MCPBanner").resizable().scaledToFit()
                    .frame(width: min(510, paneWidth * 0.44))
                    .mask {
                        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12), .init(color: .black, location: 0.88), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing)
                            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12), .init(color: .black, location: 0.85), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                    }
                    .opacity(0.8).offset(y: -24)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }

    private func benefit(_ icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            iconBadge(icon)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.custom("TimesNewRomanPS-BoldMT", size: 16))
                Text(text).foregroundStyle(muted).font(.system(size: 13))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
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
            HStack(spacing: 16) {
                Text(sharing.auth.isSignedIn ? String((sharing.email ?? "L").prefix(1)).uppercased() : "L")
                    .font(.custom("Georgia", size: 17)).foregroundStyle(.white)
                    .frame(width: 40, height: 40).background(green.gradient, in: Circle())
                Text(sharing.auth.isSignedIn ? sharing.email ?? "Connected account" : "Sign in to share your lectures")
                    .fontWeight(.medium).textSelection(.enabled)
                if sharing.auth.isSignedIn {
                    Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(green)
                }
                Spacer(minLength: 0)
            }
            if let warning = sharing.auth.credentialWarning {
                Text(warning).font(.callout).foregroundStyle(.orange)
            }
        }
    }

    private var filteredCourses: [Course] {
        courses.filter { course in
            (search.isEmpty || course.name.localizedStandardContains(search)) &&
            (filter == .all || (filter == .selected ? isSelected(course) : !isSelected(course)))
        }
    }
    private var visibleCourses: [Course] { showsAllCourses ? filteredCourses : Array(filteredCourses.prefix(10)) }
    private func isSelected(_ course: Course) -> Bool {
        guard let id = try? LecternCloudSharing.id(for: course.persistentModelID) else { return false }
        return sharing.sharedCourseIDs.contains(id)
    }

    private var coursesCard: some View {
        card {
            cardHeading("book", "Choose courses to share", "Select which courses your AI can access. Only course names, lecture titles, dates, notes and transcripts are shared.", smallCaption: true)
                .overlay(alignment: .topTrailing) {
                    Text("\(courses.filter { isSelected($0) }.count) of \(courses.count) selected")
                        .foregroundStyle(muted).font(.system(size: 13))
                }
            HStack(spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                    TextField("Search courses...", text: $search).textFieldStyle(.plain)
                }.padding(11).background(LecternTheme.ink.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(LecternTheme.ink.opacity(0.07)))
                Menu {
                    Picker("Course filter", selection: $filter) {
                        ForEach(CourseFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    HStack {
                        Text(filter.rawValue)
                        Spacer()
                        Image(systemName: "chevron.down").foregroundStyle(muted)
                    }.font(.system(size: 12)).padding(11)
                        .frame(width: 140)
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(LecternTheme.ink.opacity(0.08)))
                }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                    .accessibilityLabel("Course filter")

            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(visibleCourses) { course in courseRow(course) }
            }
            .disabled(sharing.isBusy)
            if filteredCourses.isEmpty {
                Text(courses.isEmpty ? "Your courses will appear here once you add them to Lectern." : "No courses match your search.")
                    .foregroundStyle(muted).padding(.vertical, 24).frame(maxWidth: .infinity)
            }
            if showsAllCourses {
                Toggle("Unfiled lectures", isOn: Binding(get: { sharing.shareUnfiled }, set: { sharing.shareUnfiled = $0 }))
                    .toggleStyle(.checkbox).disabled(sharing.isBusy)
            }
            Button {
                showsAllCourses.toggle()
            } label: {
                HStack(spacing: 8) {
                    Text(showsAllCourses ? "Show fewer courses" : "Show more courses")
                    Image(systemName: showsAllCourses ? "chevron.up" : "chevron.down")
                }.fontWeight(.medium).foregroundStyle(green).frame(maxWidth: .infinity)
            }.buttonStyle(.plain)
                .help("Show all matching courses and the unfiled lectures option.")
        }
    }

    private func courseRow(_ course: Course) -> some View {
        Button {
            guard let id = try? LecternCloudSharing.id(for: course.persistentModelID) else { return }
            if sharing.sharedCourseIDs.contains(id) { sharing.sharedCourseIDs.remove(id) }
            else { sharing.sharedCourseIDs.insert(id) }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: isSelected(course) ? "checkmark.square.fill" : "square")
                    .font(.system(size: 19)).foregroundStyle(isSelected(course) ? green : Color.secondary.opacity(0.4))
                Image(systemName: "book.closed")
                    .font(.system(size: 18)).foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Color(hex: course.colorHex).gradient, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text(course.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text([course.termName, "\(course.lectures.count) lectures"].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12)).foregroundStyle(muted).lineLimit(1)
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 12).padding(.vertical, 7)
                .background(LecternTheme.ink.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
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
            VStack(alignment: .leading, spacing: 4) {
                Text("Last successful sync").font(.system(size: 11))
                HStack(spacing: 8) {
                    Circle().fill(sharing.lastSync == nil ? Color.secondary : green).frame(width: 10, height: 10)
                    Text(sharing.lastSync?.formatted(date: .abbreviated, time: .shortened) ?? "Not synced yet")
                }.font(.system(size: 13))
            }.foregroundStyle(muted)
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: upToDate ? "checkmark.circle.fill" : "info.circle").font(.system(size: 19)).foregroundStyle(green)
                VStack(alignment: .leading, spacing: 6) {
                    if upToDate {
                        Text("Shared library is up to date.").fontWeight(.semibold).foregroundStyle(green)
                        Text("ChatGPT and Claude can read it while this Mac is closed.").foregroundStyle(muted)
                    } else {
                        Text(sharing.status).foregroundStyle(muted).textSelection(.enabled)
                    }
                    if sharing.needsReview {
                        Text("Replacing uses this Mac’s selection and replaces the current hosted library. Reconnect first if access was revoked.").foregroundStyle(muted)
                        Button("Reconnect account") { Task { await sharing.signIn() } }.disabled(sharing.isBusy)
                    }
                }.font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(green.opacity(0.065), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var connectionCard: some View {
        card {
            cardHeading("link", "Connect your AI", "Add this server URL in ChatGPT or Claude.")
            HStack(spacing: 8) {
                Text(LecternCloudSharing.connectionURL.absoluteString)
                    .font(.system(size: 12, weight: .medium, design: .monospaced)).textSelection(.enabled)
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(LecternTheme.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                Button {
                    NSPasteboard.general.clearContents()
                    copiedURL = NSPasteboard.general.setString(LecternCloudSharing.connectionURL.absoluteString, forType: .string)
                } label: { Image(systemName: copiedURL ? "checkmark" : "doc.on.doc").font(.system(size: 18)) }
                    .buttonStyle(MCPButtonStyle()).help(copiedURL ? "Copied URL" : "Copy URL")
                    .accessibilityLabel(copiedURL ? "Copied URL" : "Copy URL")
            }
            Text("ChatGPT: enable developer mode and add an MCP connection with OAuth. Claude: add a custom connector. Sign in with the same Google account, approve read access, and enable Lectern in the conversation.")
                .font(.system(size: 13)).foregroundStyle(muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            setupLink("Manage connections and shared data", url: LecternCloudAuth.origin.appendingPathComponent("connect"))
            HStack(spacing: 20) {
                setupLink("ChatGPT setup", url: URL(string: "https://developers.openai.com/plugins/deploy/connect-chatgpt")!)
                setupLink("Claude setup", url: URL(string: "https://support.claude.com/en/articles/11175166-get-started-with-custom-connectors-using-remote-mcp")!)
            }
        }
    }

    private var deletionCard: some View {
        card {
            HStack(spacing: 16) {
                iconBadge("trash", destructive: true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Delete hosted library and disconnect all apps").fontWeight(.semibold)
                    Text("Removing your hosted copy keeps your local library. Copies already read by an AI service may remain with that service.")
                        .font(.system(size: 12)).foregroundStyle(muted)
                }
                Spacer(minLength: 12)
                Button("Delete and disconnect", role: .destructive) { confirmsDeletion = true }
                    .buttonStyle(MCPButtonStyle(destructive: true))
                    .disabled(!sharing.auth.isSignedIn || sharing.isBusy)
            }
        }
    }

    private func setupLink(_ title: String, url: URL) -> some View {
        Link(destination: url) { HStack(spacing: 8) { Text(title); Image(systemName: "arrow.right") } }
            .font(.system(size: 13, weight: .medium)).foregroundStyle(green)
    }
    private func iconBadge(_ icon: String, destructive: Bool = false) -> some View {
        Image(systemName: icon).font(.system(size: 20, weight: .medium))
            .foregroundStyle(destructive ? Color(hex: "AF342C") : green)
            .frame(width: 38, height: 38)
            .background((destructive ? Color.red : green).opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }
    private func cardHeading(_ icon: String, _ title: String, _ caption: String, smallCaption: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 16) {
            iconBadge(icon)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.custom("TimesNewRomanPS-BoldMT", size: 20))
                Text(caption).font(.system(size: smallCaption ? 12 : 13)).foregroundStyle(muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18, content: content)
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(LecternTheme.canvasCard, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LecternTheme.ink.opacity(0.065)))
            .shadow(color: .black.opacity(0.025), radius: 8, y: 2)
    }
}

private struct MCPButtonStyle: ButtonStyle {
    var prominent = false
    var destructive = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 18).padding(.vertical, 11)
            .foregroundStyle(prominent ? .white : destructive ? Color(hex: "AF342C") : LecternTheme.ink)
            .background(prominent ? Color(hex: "30583E") : destructive ? Color.red.opacity(0.12) : LecternTheme.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
    }
}
