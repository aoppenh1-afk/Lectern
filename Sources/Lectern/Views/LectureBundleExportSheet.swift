import AppKit
import SwiftUI

struct LectureBundleExportSheet: View {
    @Environment(\.dismiss) private var dismiss

    let lecture: Lecture
    @State private var options: LecternBundleOptions
    @State private var format: LectureShareFormat = .lectern
    @State private var errorMessage: String?

    init(lecture: Lecture) {
        self.lecture = lecture
        let availability = LectureExportAvailability(lecture: lecture)
        _options = State(initialValue: availability.normalized(LecternBundleOptions()))
    }

    private var availability: LectureExportAvailability {
        LectureExportAvailability(lecture: lecture)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    formatSection
                    contentsSection
                    if format == .lectern && (availability.hasTranscript || availability.hasNotes) {
                        textOptionsSection
                    }
                }
                .padding(22)
            }

            Divider()
            footer
        }
        .frame(width: 580, height: sheetHeight)
        .background(LecternTheme.paper)
    }

    private var header: some View {
        HStack(spacing: 13) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LecternTheme.accent.opacity(0.12))
                .frame(width: 38, height: 38)
                .overlay {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(LecternTheme.accent)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text("Export lecture")
                    .font(.system(size: 18, weight: .bold, design: .serif))
                    .foregroundStyle(LecternTheme.ink)
                Text(lecture.title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.055), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 17)
    }

    private var formatSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading("Format", detail: "Choose how the lecture will be shared.")

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(LectureShareFormat.allCases) { option in
                    formatCard(option)
                }
            }
        }
    }

    private func formatCard(_ option: LectureShareFormat) -> some View {
        let selected = format == option
        return Button {
            withAnimation(LecternTheme.standardAnimation) { format = option }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: option.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(selected ? LecternTheme.accent : .secondary)
                    .frame(width: 30, height: 30)
                    .background(
                        selected ? LecternTheme.accent.opacity(0.12) : Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(LecternTheme.ink)
                    Text(option.shortDescription)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? LecternTheme.accent : Color.secondary.opacity(0.45))
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(selected ? LecternTheme.accent.opacity(0.055) : LecternTheme.cardFill)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(selected ? LecternTheme.accent.opacity(0.55) : Color.primary.opacity(0.08),
                                  lineWidth: selected ? 1.5 : 1)
            }
        }
        .buttonStyle(.plain)
    }

    private var contentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading("Include", detail: "Only material available in this lecture is shown.")

            VStack(spacing: 0) {
                ForEach(Array(availability.components.enumerated()), id: \.element.id) { index, component in
                    contentRow(component)
                    if index < availability.components.count - 1 {
                        Divider().padding(.leading, 42)
                    }
                }

                if availability.components.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                        Text("This lecture has no generated material yet. The export will contain its title and date.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    .padding(13)
                }
            }
            .background(LecternTheme.cardFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
        }
    }

    private func contentRow(_ component: LectureExportAvailability.Component) -> some View {
        HStack(spacing: 11) {
            Image(systemName: component.icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(LecternTheme.accent)
                .frame(width: 30, height: 30)
                .background(LecternTheme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(component.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(LecternTheme.ink)
                Text(component.subtitle(for: lecture))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: binding(for: component.kind))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(LecternTheme.accent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var textOptionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading("Package text", detail: "Formatting used inside the Lectern bundle.")

            VStack(spacing: 0) {
                if availability.hasTranscript {
                    textFormatRow("Transcript", selection: $options.transcriptFormat)
                }
                if availability.hasTranscript && availability.hasNotes {
                    Divider().padding(.leading, 12)
                }
                if availability.hasNotes {
                    textFormatRow("Notes", selection: $options.notesFormat)
                    Divider().padding(.leading, 12)
                    HStack {
                        Text("Copy linked diagram files")
                            .font(.system(size: 11.5))
                        Spacer()
                        Toggle("", isOn: $options.includeDiagrams)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .tint(LecternTheme.accent)
                            .disabled(!options.includeNotes || options.notesFormat == .plainText)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                }
            }
            .background(LecternTheme.cardFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
        }
    }

    private func textFormatRow(_ title: String,
                               selection: Binding<LecternBundleOptions.TextFormat>) -> some View {
        HStack {
            Text(title).font(.system(size: 11.5))
            Spacer()
            Picker(title, selection: selection) {
                ForEach(LecternBundleOptions.TextFormat.allCases) { textFormat in
                    Text(textFormat.title).tag(textFormat)
                }
            }
            .labelsHidden()
            .frame(width: 130)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func sectionHeading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(LecternTheme.ink)
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(selectedCount) item\(selectedCount == 1 ? "" : "s") selected")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(LecternTheme.ink)
                Text("\(safeFilename(lecture.title)).\(format.fileExtension)")
                    .font(.system(size: 10.5).monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            Button("Cancel", role: .cancel) { dismiss() }
            Button("Export \(format.title)…", action: export)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(LecternTheme.accent)
        }
        .overlay(alignment: .topLeading) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
                    .offset(y: -19)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private var selectedCount: Int {
        let normalized = availability.normalized(options)
        return [
            normalized.includeTranscript,
            normalized.includeNotes,
            normalized.includeFlashcards,
            normalized.includeQuiz,
            normalized.includeBookmarks,
            normalized.includeReferenceFiles,
        ].filter { $0 }.count
    }

    private var sheetHeight: CGFloat {
        let additionalRows = max(0, availability.components.count - 1)
        let notesOptions: CGFloat = format == .lectern && availability.hasNotes ? 50 : 0
        return min(720, 540 + CGFloat(additionalRows * 44) + notesOptions)
    }

    private func binding(for kind: LectureExportAvailability.Kind) -> Binding<Bool> {
        Binding {
            switch kind {
            case .transcript: return options.includeTranscript
            case .notes: return options.includeNotes
            case .flashcards: return options.includeFlashcards
            case .quiz: return options.includeQuiz
            case .bookmarks: return options.includeBookmarks
            case .attachments: return options.includeReferenceFiles
            }
        } set: { enabled in
            switch kind {
            case .transcript: options.includeTranscript = enabled
            case .notes: options.includeNotes = enabled
            case .flashcards: options.includeFlashcards = enabled
            case .quiz: options.includeQuiz = enabled
            case .bookmarks: options.includeBookmarks = enabled
            case .attachments: options.includeReferenceFiles = enabled
            }
        }
    }

    private func export() {
        let preparedOptions = availability.normalized(options)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(safeFilename(lecture.title)).\(format.fileExtension)"
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.pathExtension.lowercased() != format.fileExtension {
            url.appendPathExtension(format.fileExtension)
        }
        do {
            if format == .lectern {
                try LecternBundleService.export(lecture, to: url, options: preparedOptions)
            } else {
                try LectureDocumentExportService.export(
                    lecture, to: url, format: format, options: preparedOptions
                )
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func safeFilename(_ value: String) -> String {
        value.replacingOccurrences(of: #"[/:]"#, with: "-", options: .regularExpression)
    }
}

private extension LectureShareFormat {
    var icon: String {
        switch self {
        case .lectern: return "shippingbox.fill"
        case .markdown: return "text.alignleft"
        case .pdf: return "doc.richtext.fill"
        case .docx: return "doc.text.fill"
        }
    }

    var shortDescription: String {
        switch self {
        case .lectern: return "Import into Lectern"
        case .markdown: return "Portable plain text"
        case .pdf: return "Ready to read or print"
        case .docx: return "Editable in Word"
        }
    }
}

private extension LectureExportAvailability.Component {
    var icon: String {
        switch kind {
        case .transcript: return "text.quote"
        case .notes: return "note.text"
        case .flashcards: return "rectangle.on.rectangle.angled"
        case .quiz: return "checkmark.circle"
        case .bookmarks: return "bookmark"
        case .attachments: return "paperclip"
        }
    }

    var title: String {
        switch kind {
        case .transcript: return "Transcript"
        case .notes: return "Notes and diagrams"
        case .flashcards: return "Flashcards"
        case .quiz: return "Quiz"
        case .bookmarks: return "Bookmarks and exam alerts"
        case .attachments: return "Attached notes and slides"
        }
    }

    func subtitle(for lecture: Lecture) -> String {
        switch kind {
        case .transcript:
            return lecture.artifact(of: .cleanedTranscript) == nil ? "Raw transcript" : "Cleaned transcript"
        case .notes:
            return "Generated lecture notes"
        case .flashcards:
            return "\(count) card\(count == 1 ? "" : "s")"
        case .quiz:
            return "\(count) question\(count == 1 ? "" : "s")"
        case .bookmarks:
            return "\(count) saved moment\(count == 1 ? "" : "s")"
        case .attachments:
            return "\(count) reference file\(count == 1 ? "" : "s")"
        }
    }
}
