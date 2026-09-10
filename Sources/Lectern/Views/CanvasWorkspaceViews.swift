import SwiftData
import SwiftUI

struct StudioDropdownOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var subtitle: String?

    var id: Value { value }
}

struct StudioDropdown<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [StudioDropdownOption<Value>]
    var width: CGFloat = 240
    var icon: String? = nil
    @State private var isPresented = false

    private var selectedTitle: String {
        options.first(where: { $0.value == selection })?.title ?? title
    }

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(LecternTheme.accent)
                }
                Text(selectedTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 10)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(LecternTheme.ink)
            .padding(.horizontal, 11)
            .frame(width: width, height: 38)
            .background(LecternTheme.canvasCard, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(LecternTheme.hairline))
            .shadow(color: Color.black.opacity(0.04), radius: 5, y: 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased())
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 9)
                    .padding(.bottom, 3)

                ForEach(options) { option in
                    Button {
                        selection = option.value
                        isPresented = false
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title).font(.system(size: 12.5, weight: .medium))
                                if let subtitle = option.subtitle {
                                    Text(subtitle).font(.system(size: 9.5)).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 16)
                            if selection == option.value {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(LecternTheme.accent)
                            }
                        }
                        .foregroundStyle(LecternTheme.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(selection == option.value ? Color.primary.opacity(0.07) : .clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .frame(width: max(width, 220))
            .background(LecternTheme.paper)
        }
    }
}

struct CanvasCalendarView: View {
    enum Mode: String, CaseIterable, Identifiable { case day = "Day", week = "Week", month = "Month"; var id: String { rawValue } }
    @Query(sort: \CanvasEvent.startAt) private var events: [CanvasEvent]
    @Query(sort: \CanvasAssignment.dueAt) private var assignments: [CanvasAssignment]
    @Query(sort: \Course.name) private var courses: [Course]
    let allowedCourseIDs: Set<Int64>
    @State private var anchorDate = Date()
    @State private var mode: Mode = .month
    @State private var showingEventSheet = false
    @State private var sheetInitialDate = Date()
    @State private var editingEvent: CanvasEvent?

    private var scopedEvents: [CanvasEvent] {
        events.filter { event in
            // Manual events are the student's own and always stay visible,
            // regardless of the selected academic term.
            if event.isManual { return true }
            return event.courseCanvasID.map(allowedCourseIDs.contains) ?? false
        }
        .sorted { $0.startAt < $1.startAt }
    }
    private var scopedAssignments: [CanvasAssignment] { assignments.filter { allowedCourseIDs.contains($0.courseCanvasID) } }

    var body: some View {
        StudioPage(title: "Calendar", subtitle: "Your Fall 2026 schedule, Canvas deadlines, and personal events") {
            HStack(alignment: .top, spacing: 10) {
                HStack(spacing: 10) {
                    Button { move(-1) } label: { Image(systemName: "chevron.left") }
                    Button { move(1) } label: { Image(systemName: "chevron.right") }
                    Button("Today") { anchorDate = Date() }
                    Text(calendarTitle).font(.system(size: 20, weight: .semibold, design: .serif)).padding(.leading, 8)
                }
                .buttonStyle(.bordered)
                .padding(.top, 26)
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    Button {
                        sheetInitialDate = anchorDate
                        showingEventSheet = true
                    } label: {
                        Label("Add Event", systemImage: "plus")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(LecternTheme.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("Add a personal event to your calendar")
                    Picker("View", selection: $mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).frame(width: 250)
                }
            }
            Group {
                switch mode {
                case .day: dayView(anchorDate)
                case .week: weekView
                case .month: monthView
                }
            }
            .studioPanel()
        }
        .sheet(isPresented: $showingEventSheet) {
            ManualEventSheet(initialDate: sheetInitialDate, courses: courses)
        }
        .sheet(item: $editingEvent) { event in
            ManualEventSheet(editing: event, courses: courses)
        }
    }

    private var calendarTitle: String {
        switch mode {
        case .day: return anchorDate.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
        case .week:
            let dates = weekDates
            return "\(dates.first?.formatted(.dateTime.month(.wide).day()) ?? "") – \(dates.last?.formatted(.dateTime.month(.wide).day().year()) ?? "")"
        case .month: return anchorDate.formatted(.dateTime.month(.wide).year())
        }
    }

    private func move(_ direction: Int) {
        let component: Calendar.Component = mode == .day ? .day : mode == .week ? .weekOfYear : .month
        anchorDate = Calendar.current.date(byAdding: component, value: direction, to: anchorDate) ?? anchorDate
    }

    private var weekDates: [Date] {
        let interval = Calendar.current.dateInterval(of: .weekOfYear, for: anchorDate)
        return (0..<7).compactMap { offset in
            interval.flatMap { week in Calendar.current.date(byAdding: .day, value: offset, to: week.start) }
        }
    }

    private var monthDates: [Date] {
        guard let month = Calendar.current.dateInterval(of: .month, for: anchorDate),
              let gridStart = Calendar.current.dateInterval(of: .weekOfYear, for: month.start)?.start else { return [] }
        return (0..<42).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: gridStart) }
    }

    private var monthView: some View {
        VStack(spacing: 0) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
                ForEach(Calendar.current.shortWeekdaySymbols, id: \.self) { Text($0.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 9) }
                ForEach(monthDates, id: \.self) { day in monthCell(day) }
            }
        }
    }

    private func manualEventColor(_ event: CanvasEvent) -> Color {
        if let courseID = event.courseCanvasID,
           let course = courses.first(where: { $0.canvasID == courseID }) {
            return Color(hex: course.colorHex)
        }
        if let name = event.courseName,
           let course = courses.first(where: { $0.name == name }) {
            return Color(hex: course.colorHex)
        }
        return LecternTheme.accent
    }

    private func monthCell(_ day: Date) -> some View {
        let dayEvents = scopedEvents.filter { Calendar.current.isDate($0.startAt, inSameDayAs: day) }
        let dayAssignments = scopedAssignments.filter { $0.dueAt.map { Calendar.current.isDate($0, inSameDayAs: day) } ?? false }
        return VStack(alignment: .leading, spacing: 4) {
            Text(day.formatted(.dateTime.day())).font(.system(size: 11, weight: Calendar.current.isDateInToday(day) ? .bold : .regular))
                .foregroundStyle(Calendar.current.isDate(day, equalTo: anchorDate, toGranularity: .month) ? LecternTheme.ink : Color.secondary.opacity(0.45))
                .padding(5)
                .background(Calendar.current.isDateInToday(day) ? LecternTheme.accent.opacity(0.14) : .clear, in: Circle())
            ForEach(dayEvents.prefix(2)) { event in
                if event.isManual {
                    Button { editingEvent = event } label: {
                        calendarChip(event.title, color: manualEventColor(event), icon: "person.fill")
                    }
                    .buttonStyle(.plain)
                } else {
                    calendarChip(event.title, color: LecternTheme.accent)
                }
            }
            ForEach(dayAssignments.prefix(max(0, 3 - dayEvents.count))) { assignment in calendarChip(assignment.title, color: LecternTheme.warningTint) }
            if dayEvents.count + dayAssignments.count > 3 { Text("+\(dayEvents.count + dayAssignments.count - 3) more").font(.system(size: 9)).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
        }
        .padding(7).frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
        .overlay(Rectangle().stroke(LecternTheme.hairline, lineWidth: 0.5))
        .contentShape(Rectangle()).onTapGesture { anchorDate = day; mode = .day }
    }

    private var weekView: some View {
        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(weekDates, id: \.self) { day in
                    VStack(spacing: 0) {
                        HStack(spacing: 6) {
                            VStack(spacing: 3) { Text(day.formatted(.dateTime.weekday(.abbreviated))).font(.system(size: 10, weight: .semibold)); Text(day.formatted(.dateTime.day())).font(.system(size: 18, design: .serif)) }
                            Spacer()
                            Button {
                                sheetInitialDate = day
                                showingEventSheet = true
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(5)
                                    .background(Color.primary.opacity(0.05), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .help("Add an event on \(day.formatted(date: .abbreviated, time: .omitted))")
                        }.padding(10)
                        Divider()
                        let dayEvents = scopedEvents.filter { Calendar.current.isDate($0.startAt, inSameDayAs: day) }
                        let dayAssignments = scopedAssignments.filter { $0.dueAt.map { Calendar.current.isDate($0, inSameDayAs: day) } ?? false }
                        VStack(spacing: 8) {
                            ForEach(dayEvents) { eventRow($0) }
                            ForEach(dayAssignments) { AssignmentAgendaRow(assignment: $0) }
                            if dayEvents.isEmpty && dayAssignments.isEmpty { Text("No events").font(.system(size: 10)).foregroundStyle(.tertiary).padding(.top, 30) }
                        }.padding(8)
                    }
                    .frame(minWidth: 150, maxWidth: .infinity, minHeight: 570, alignment: .top)
                    .overlay(alignment: .trailing) { Divider() }
                }
            }
        }
    }

    private func dayView(_ day: Date) -> some View {
        let dayEvents = scopedEvents.filter { Calendar.current.isDate($0.startAt, inSameDayAs: day) }
        let dayAssignments = scopedAssignments.filter { $0.dueAt.map { Calendar.current.isDate($0, inSameDayAs: day) } ?? false }
        return ScrollView {
            VStack(spacing: 0) {
                HStack {
                    Text(day.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        sheetInitialDate = day
                        showingEventSheet = true
                    } label: {
                        Label("Add event", systemImage: "plus")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(LecternTheme.accent)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 4)
                ForEach(0..<24, id: \.self) { hour in
                    HStack(alignment: .top, spacing: 16) {
                        Text(Calendar.current.date(from: DateComponents(hour: hour))?.formatted(date: .omitted, time: .shortened) ?? "")
                            .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                        VStack(spacing: 6) {
                            ForEach(dayEvents.filter { Calendar.current.component(.hour, from: $0.startAt) == hour }) { eventRow($0) }
                            ForEach(dayAssignments.filter { ($0.dueAt.map { Calendar.current.component(.hour, from: $0) } ?? -1) == hour }) { AssignmentAgendaRow(assignment: $0) }
                            Divider()
                        }.frame(maxWidth: .infinity, minHeight: 54, alignment: .top)
                    }.padding(.horizontal, 14)
                }
            }.padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private func eventRow(_ event: CanvasEvent) -> some View {
        if event.isManual {
            Button { editingEvent = event } label: {
                EventAgendaRow(event: event, tint: manualEventColor(event), showsPersonalBadge: true)
            }
            .buttonStyle(.plain)
            .help("Edit personal event")
        } else {
            EventAgendaRow(event: event)
        }
    }

    private func calendarChip(_ title: String, color: Color, icon: String? = nil) -> some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon).font(.system(size: 8, weight: .semibold))
            }
            Text(title).font(.system(size: 9.5, weight: .medium)).lineLimit(1)
        }
        .padding(.horizontal, 5).padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading).background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(color)
    }
}

struct ManualEventSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let editing: CanvasEvent?
    let initialDate: Date
    let courses: [Course]

    init(initialDate: Date = Date(), courses: [Course] = []) {
        self.editing = nil
        self.initialDate = initialDate
        self.courses = courses
    }

    init(editing: CanvasEvent, courses: [Course] = []) {
        self.editing = editing
        self.initialDate = editing.startAt
        self.courses = courses
    }

    @State private var title = ""
    @State private var selectedCourseID: PersistentIdentifier?
    @State private var eventDate = Date()
    @State private var isAllDay = false
    @State private var startsAt = Date()
    @State private var endsAt = Date()
    @State private var location = ""
    @State private var notes = ""
    @State private var showingDeleteConfirm = false
    @FocusState private var titleFocused: Bool

    private var isEditing: Bool { editing != nil }
    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var endsBeforeStart: Bool { !isAllDay && endsAt < startsAt }
    private var canSave: Bool { !trimmedTitle.isEmpty && !endsBeforeStart }

    private var selectedCourse: Course? {
        guard let id = selectedCourseID else { return nil }
        return courses.first { $0.persistentModelID == id }
    }

    private var scheduleSummary: String {
        if isAllDay {
            return "\(eventDate.formatted(date: .complete, time: .omitted)) · All day"
        }
        let day = eventDate.formatted(date: .complete, time: .omitted)
        return "\(day) · \(startsAt.formatted(date: .omitted, time: .shortened)) – \(endsAt.formatted(date: .omitted, time: .shortened))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            detailsCard
            scheduleCard
            notesCard
            footer
        }
        .padding(24)
        .frame(width: 500)
        .background(LecternTheme.paper)
        .onAppear(perform: populate)
        .alert("Delete this event?", isPresented: $showingDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive, action: delete)
        } message: {
            Text("This personal event will be removed from your calendar. Canvas deadlines are never affected.")
        }
    }

    private func populate() {
        if let editing {
            title = editing.title
            eventDate = editing.startAt
            location = editing.locationName ?? ""
            notes = editing.detailsHTML ?? ""
            let components = Calendar.current.dateComponents([.hour, .minute], from: editing.startAt)
            if editing.endAt == nil && components.hour == 0 && components.minute == 0 {
                isAllDay = true
                startsAt = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: editing.startAt) ?? editing.startAt
                endsAt = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: editing.startAt) ?? editing.startAt
            } else {
                isAllDay = false
                startsAt = editing.startAt
                endsAt = editing.endAt ?? Calendar.current.date(byAdding: .hour, value: 1, to: editing.startAt) ?? editing.startAt
            }
            if let canvasID = editing.courseCanvasID {
                selectedCourseID = courses.first(where: { $0.canvasID == canvasID })?.persistentModelID
                    ?? courses.first(where: { $0.name == editing.courseName })?.persistentModelID
            } else if let name = editing.courseName {
                selectedCourseID = courses.first(where: { $0.name == name })?.persistentModelID
            }
        } else {
            let start = Self.roundedUpToHour(initialDate)
            eventDate = initialDate
            startsAt = start
            endsAt = Calendar.current.date(byAdding: .hour, value: 1, to: start) ?? start
        }
        titleFocused = true
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(isEditing ? "Edit Event" : "New Event")
                .font(.system(size: 20, weight: .bold, design: .serif))
                .foregroundStyle(LecternTheme.ink)
            Text("Personal events live alongside Canvas deadlines. Canvas items stay read-only.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                SettingsFieldLabel(title: "Title")
                SettingsTextField(placeholder: "Study group, dentist, review session…", text: $title)
                    .focused($titleFocused)
                    .onSubmit(saveIfValid)
            }
            Divider()
            HStack {
                SettingsFieldLabel(title: "Course")
                Spacer()
                Picker("Course", selection: $selectedCourseID) {
                    Text("Personal").tag(PersistentIdentifier?.none)
                    if !courses.isEmpty {
                        Divider()
                        ForEach(courses) { course in
                            Text(course.name).tag(PersistentIdentifier?.some(course.persistentModelID))
                        }
                    }
                }
                .labelsHidden()
                .frame(width: 220)
            }
            if let course = selectedCourse {
                HStack(spacing: 8) {
                    CourseBadge(colorHex: course.colorHex, initial: String(course.name.prefix(1)), size: 20)
                    Text(course.courseCode ?? course.termName ?? "Linked course")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                SettingsFieldLabel(title: "Location")
                SettingsTextField(placeholder: "Library room 3, Zoom, home…", text: $location)
            }
        }
        .padding(14)
        .background(LecternTheme.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(LecternTheme.hairline))
    }

    private var scheduleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SettingsFieldLabel(title: "Date")
                Spacer()
                DatePicker("Date", selection: $eventDate, displayedComponents: .date)
                    .labelsHidden()
            }
            Divider()
            Toggle(isOn: $isAllDay) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("All day").font(.system(size: 12.5, weight: .medium))
                    Text("No start or end time").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            if !isAllDay {
                Divider()
                HStack {
                    SettingsFieldLabel(title: "Starts")
                    Spacer()
                    DatePicker("Starts", selection: $startsAt, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                }
                HStack {
                    SettingsFieldLabel(title: "Ends")
                    Spacer()
                    DatePicker("Ends", selection: $endsAt, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                }
                if endsBeforeStart {
                    Label("End time is before the start time.", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(LecternTheme.warningTint)
                }
            }
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(.system(size: 11))
                    .foregroundStyle(LecternTheme.accent)
                Text(scheduleSummary)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(LecternTheme.ink)
                Spacer()
            }
        }
        .padding(14)
        .background(LecternTheme.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(LecternTheme.hairline))
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsFieldLabel(title: "Notes")
            TextEditor(text: $notes)
                .font(.system(size: 12.5))
                .foregroundStyle(LecternTheme.ink)
                .frame(minHeight: 64, maxHeight: 110)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(LecternTheme.surfaceFill, in: RoundedRectangle(cornerRadius: LecternTheme.controlRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: LecternTheme.controlRadius, style: .continuous).stroke(LecternTheme.hairline))
        }
        .padding(14)
        .background(LecternTheme.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(LecternTheme.hairline))
    }

    private var footer: some View {
        HStack {
            if isEditing {
                Button(role: .destructive) { showingDeleteConfirm = true } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(isEditing ? "Save Changes" : "Add Event", action: saveIfValid)
                .keyboardShortcut(.defaultAction)
                .prominentAction()
                .tint(LecternTheme.accent)
                .disabled(!canSave)
        }
    }

    private func saveIfValid() {
        guard canSave else { return }
        save()
    }

    private static func roundedUpToHour(_ date: Date) -> Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard let hour = components.hour else { return date }
        if (components.minute ?? 0) == 0 { return calendar.date(bySetting: .second, value: 0, of: date) ?? date }
        return calendar.date(bySettingHour: hour + 1, minute: 0, second: 0, of: date) ?? date
    }

    private func combinedDate(day: Date, time: Date) -> Date {
        let calendar = Calendar.current
        let dayParts = calendar.dateComponents([.year, .month, .day], from: day)
        let timeParts = calendar.dateComponents([.hour, .minute], from: time)
        var merged = DateComponents()
        merged.year = dayParts.year
        merged.month = dayParts.month
        merged.day = dayParts.day
        merged.hour = timeParts.hour
        merged.minute = timeParts.minute
        return calendar.date(from: merged) ?? day
    }

    private func save() {
        let start: Date
        let end: Date?
        if isAllDay {
            start = Calendar.current.startOfDay(for: eventDate)
            end = nil
        } else {
            start = combinedDate(day: eventDate, time: startsAt)
            end = combinedDate(day: eventDate, time: endsAt)
        }
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLocation = location.trimmingCharacters(in: .whitespacesAndNewlines)
        if let editing {
            editing.title = trimmedTitle
            editing.startAt = start
            editing.endAt = end
            editing.locationName = trimmedLocation.isEmpty ? nil : trimmedLocation
            editing.detailsHTML = trimmedNotes.isEmpty ? nil : trimmedNotes
            editing.courseCanvasID = selectedCourse?.canvasID
            editing.courseName = selectedCourse?.name
            editing.syncedAt = Date()
        } else {
            let event = CanvasEvent(canvasID: CanvasEvent.makeLocalID(), title: trimmedTitle, startAt: start)
            event.endAt = end
            event.locationName = trimmedLocation.isEmpty ? nil : trimmedLocation
            event.detailsHTML = trimmedNotes.isEmpty ? nil : trimmedNotes
            event.courseCanvasID = selectedCourse?.canvasID
            event.courseName = selectedCourse?.name
            modelContext.insert(event)
        }
        try? modelContext.save()
        dismiss()
    }

    private func delete() {
        if let editing {
            modelContext.delete(editing)
            try? modelContext.save()
        }
        dismiss()
    }
}

struct ManualAssignmentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let editing: CanvasAssignment?
    let courses: [Course]

    init(courses: [Course] = []) {
        self.editing = nil
        self.courses = courses
    }

    init(editing: CanvasAssignment, courses: [Course] = []) {
        self.editing = editing
        self.courses = courses
    }

    @State private var title = ""
    @State private var selectedCourseID: PersistentIdentifier?
    @State private var dueDate = Date()
    @State private var dueTime = Date()
    @State private var pointsText = ""
    @State private var notes = ""
    @State private var isComplete = false
    @State private var showingDeleteConfirm = false
    @FocusState private var titleFocused: Bool

    private var isEditing: Bool { editing != nil }
    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmedTitle.isEmpty }

    private var selectedCourse: Course? {
        guard let id = selectedCourseID else { return nil }
        return courses.first { $0.persistentModelID == id }
    }

    private var dueSummary: String {
        let day = dueDate.formatted(date: .complete, time: .omitted)
        return "\(day) · \(dueTime.formatted(date: .omitted, time: .shortened))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            detailsCard
            scheduleCard
            notesCard
            if isEditing { statusCard }
            footer
        }
        .padding(24)
        .frame(width: 500)
        .background(LecternTheme.paper)
        .onAppear(perform: populate)
        .alert("Delete this assignment?", isPresented: $showingDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive, action: delete)
        } message: {
            Text("This personal assignment will be removed. Canvas assignments are never affected.")
        }
    }

    private func populate() {
        if let editing {
            title = editing.title
            if let due = editing.dueAt {
                dueDate = due
                dueTime = due
            } else {
                dueDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
                dueTime = Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: Date()) ?? Date()
            }
            if let points = editing.pointsPossible {
                pointsText = points.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(points)) : String(points)
            }
            notes = editing.detailsHTML ?? ""
            isComplete = editing.isComplete
            if editing.courseCanvasID != 0 {
                selectedCourseID = courses.first(where: { $0.canvasID == editing.courseCanvasID })?.persistentModelID
                    ?? courses.first(where: { $0.name == editing.courseName })?.persistentModelID
            } else if editing.courseName != "Personal" {
                selectedCourseID = courses.first(where: { $0.name == editing.courseName })?.persistentModelID
            }
        } else {
            dueDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
            dueTime = Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: Date()) ?? Date()
        }
        titleFocused = true
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(isEditing ? "Edit Assignment" : "New Assignment")
                .font(.system(size: 20, weight: .bold, design: .serif))
                .foregroundStyle(LecternTheme.ink)
            Text("Personal assignments live alongside Canvas work. Canvas items stay read-only.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                SettingsFieldLabel(title: "Title")
                SettingsTextField(placeholder: "Problem set 4, essay draft, lab report…", text: $title)
                    .focused($titleFocused)
                    .onSubmit(saveIfValid)
            }
            Divider()
            HStack {
                SettingsFieldLabel(title: "Course")
                Spacer()
                Picker("Course", selection: $selectedCourseID) {
                    Text("Personal").tag(PersistentIdentifier?.none)
                    if !courses.isEmpty {
                        Divider()
                        ForEach(courses) { course in
                            Text(course.name).tag(PersistentIdentifier?.some(course.persistentModelID))
                        }
                    }
                }
                .labelsHidden()
                .frame(width: 220)
            }
            if let course = selectedCourse {
                HStack(spacing: 8) {
                    CourseBadge(colorHex: course.colorHex, initial: String(course.name.prefix(1)), size: 20)
                    Text(course.courseCode ?? course.termName ?? "Linked course")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    SettingsFieldLabel(title: "Points possible")
                    Text("Optional").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer()
                TextField("e.g. 100", text: $pointsText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(14)
        .background(LecternTheme.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(LecternTheme.hairline))
    }

    private var scheduleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SettingsFieldLabel(title: "Due date")
                Spacer()
                DatePicker("Due date", selection: $dueDate, displayedComponents: .date)
                    .labelsHidden()
            }
            Divider()
            HStack {
                SettingsFieldLabel(title: "Due time")
                Spacer()
                DatePicker("Due time", selection: $dueTime, displayedComponents: .hourAndMinute)
                    .labelsHidden()
            }
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(.system(size: 11))
                    .foregroundStyle(LecternTheme.accent)
                Text("Due \(dueSummary)")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(LecternTheme.ink)
                Spacer()
            }
        }
        .padding(14)
        .background(LecternTheme.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(LecternTheme.hairline))
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsFieldLabel(title: "Notes")
            TextEditor(text: $notes)
                .font(.system(size: 12.5))
                .foregroundStyle(LecternTheme.ink)
                .frame(minHeight: 64, maxHeight: 110)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(LecternTheme.surfaceFill, in: RoundedRectangle(cornerRadius: LecternTheme.controlRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: LecternTheme.controlRadius, style: .continuous).stroke(LecternTheme.hairline))
        }
        .padding(14)
        .background(LecternTheme.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(LecternTheme.hairline))
    }

    private var statusCard: some View {
        Toggle(isOn: $isComplete) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Completed").font(.system(size: 12.5, weight: .medium))
                Text("Finished work moves to Submitted").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .padding(14)
        .background(LecternTheme.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(LecternTheme.hairline))
    }

    private var footer: some View {
        HStack {
            if isEditing {
                Button(role: .destructive) { showingDeleteConfirm = true } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(isEditing ? "Save Changes" : "Add Assignment", action: saveIfValid)
                .keyboardShortcut(.defaultAction)
                .prominentAction()
                .tint(LecternTheme.accent)
                .disabled(!canSave)
        }
    }

    private func saveIfValid() {
        guard canSave else { return }
        save()
    }

    private func combinedDue() -> Date {
        let calendar = Calendar.current
        let dayParts = calendar.dateComponents([.year, .month, .day], from: dueDate)
        let timeParts = calendar.dateComponents([.hour, .minute], from: dueTime)
        var merged = DateComponents()
        merged.year = dayParts.year
        merged.month = dayParts.month
        merged.day = dayParts.day
        merged.hour = timeParts.hour
        merged.minute = timeParts.minute
        return calendar.date(from: merged) ?? dueDate
    }

    private func save() {
        let due = combinedDue()
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let points = Double(pointsText.trimmingCharacters(in: .whitespacesAndNewlines))
        if let editing {
            editing.title = trimmedTitle
            editing.dueAt = due
            editing.pointsPossible = points
            editing.detailsHTML = trimmedNotes.isEmpty ? nil : trimmedNotes
            editing.courseCanvasID = selectedCourse?.canvasID ?? 0
            editing.courseName = selectedCourse?.name ?? "Personal"
            editing.courseCode = selectedCourse?.courseCode
            editing.submissionState = isComplete ? "submitted" : nil
            editing.syncedAt = Date()
        } else {
            let assignment = CanvasAssignment(
                canvasID: CanvasAssignment.makeLocalID(),
                courseCanvasID: selectedCourse?.canvasID ?? 0,
                courseName: selectedCourse?.name ?? "Personal",
                title: trimmedTitle
            )
            assignment.dueAt = due
            assignment.pointsPossible = points
            assignment.detailsHTML = trimmedNotes.isEmpty ? nil : trimmedNotes
            assignment.courseCode = selectedCourse?.courseCode
            modelContext.insert(assignment)
        }
        try? modelContext.save()
        dismiss()
    }

    private func delete() {
        if let editing {
            modelContext.delete(editing)
            try? modelContext.save()
        }
        dismiss()
    }
}

struct CanvasAssignmentsView: View {
    enum Filter: String, CaseIterable, Identifiable { case upcoming = "Upcoming", missing = "Missing", submitted = "Submitted", all = "All"; var id: String { rawValue } }
    @Environment(\.openURL) private var openURL
    @Query(sort: \CanvasAssignment.dueAt) private var assignments: [CanvasAssignment]
    let courses: [Course]
    let allowedCourseIDs: Set<Int64>
    @State private var filter: Filter = .upcoming
    @State private var selectedCourseID: Int64?
    @State private var search = ""

    @State private var showingAddSheet = false
    @State private var editingAssignment: CanvasAssignment?

    private var visible: [CanvasAssignment] {
        assignments.filter { assignment in
            // Manual assignments are the student's own and always stay visible,
            // regardless of the selected academic term.
            guard assignment.isManual || allowedCourseIDs.contains(assignment.courseCanvasID) else { return false }
            guard selectedCourseID == nil || selectedCourseID == assignment.courseCanvasID else { return false }
            let matchesSearch = search.isEmpty || assignment.title.localizedCaseInsensitiveContains(search) || assignment.courseName.localizedCaseInsensitiveContains(search)
            let matchesFilter = switch filter {
            case .upcoming: !assignment.isComplete && (assignment.dueAt ?? .distantFuture) >= Calendar.current.startOfDay(for: Date())
            case .missing: assignment.isMissing
            case .submitted: assignment.isComplete
            case .all: true
            }
            return matchesSearch && matchesFilter
        }
    }

    private var courseOptions: [StudioDropdownOption<Int64?>] {
        [StudioDropdownOption(value: nil, title: "All courses")] + courses.compactMap { course in
            course.canvasID.map { StudioDropdownOption(value: Optional($0), title: course.name, subtitle: course.courseCode) }
        }
    }

    var body: some View {
        StudioPage(title: "Assignments", subtitle: "Fall 2026 work, filterable by course and status") {
            HStack {
                Picker("Filter", selection: $filter) { ForEach(Filter.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 380)
                Spacer()
                StudioDropdown(title: "Course", selection: $selectedCourseID, options: courseOptions, width: 230, icon: "book.closed")
                TextField("Search assignments", text: $search).textFieldStyle(.roundedBorder).frame(width: 260)
                Button { showingAddSheet = true } label: {
                    Label("Add Assignment", systemImage: "plus")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(LecternTheme.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Add a personal assignment")
            }
            ScrollView {
                LazyVStack(spacing: 10) {
                    if visible.isEmpty { ContentUnavailableView("No assignments", systemImage: "checklist", description: Text("Nothing matches this view.")) }
                    ForEach(visible) { assignment in
                        assignmentRow(assignment)
                    }
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            ManualAssignmentSheet(courses: courses)
        }
        .sheet(item: $editingAssignment) { assignment in
            ManualAssignmentSheet(editing: assignment, courses: courses)
        }
    }

    @ViewBuilder
    private func assignmentRow(_ assignment: CanvasAssignment) -> some View {
        if assignment.isManual {
            Button { editingAssignment = assignment } label: {
                HStack(spacing: 14) {
                    Image(systemName: assignment.isComplete ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18)).foregroundStyle(assignment.isComplete ? LecternTheme.successTint : .secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(assignment.title).font(.system(size: 13.5, weight: .semibold)); StatusChip("Personal", LecternTheme.accent) }
                        Text("\(assignment.courseCode ?? assignment.courseName) · \(assignmentDetail(assignment))").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(relativeDue(assignment.dueAt)).font(.system(size: 11, weight: .semibold)).foregroundStyle(LecternTheme.accent)
                    Image(systemName: "pencil").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                .padding(15).studioPanel()
            }
            .buttonStyle(.plain)
            .help("Edit personal assignment")
        } else {
            Button {
                if let value = assignment.htmlURL, let url = URL(string: value) { openURL(url) }
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: assignment.isComplete ? "checkmark.circle.fill" : assignment.isMissing ? "exclamationmark.circle.fill" : "circle")
                        .font(.system(size: 18)).foregroundStyle(assignment.isComplete ? LecternTheme.successTint : assignment.isMissing ? LecternTheme.warningTint : .secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(assignment.title).font(.system(size: 13.5, weight: .semibold)); if assignment.isMissing { StatusChip("Missing", LecternTheme.warningTint) } }
                        Text("\(assignment.courseCode ?? assignment.courseName) · \(assignmentDetail(assignment))").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(relativeDue(assignment.dueAt)).font(.system(size: 11, weight: .semibold)).foregroundStyle(LecternTheme.accent)
                    Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                .padding(15).studioPanel()
            }
            .buttonStyle(.plain)
        }
    }
}

struct CanvasGradesView: View {
    @Query private var assignments: [CanvasAssignment]
    let courses: [Course]
    let allowedCourseIDs: Set<Int64>
    @State private var selectedCourseID: PersistentIdentifier?
    private var gradedCourses: [Course] { courses.filter { $0.canvasID.map(allowedCourseIDs.contains) ?? false } }
    private var selectedCourse: Course? { gradedCourses.first { $0.persistentModelID == selectedCourseID } }

    var body: some View {
        StudioPage(title: "Grades", subtitle: "Current Canvas standing with assignment-level results") {
            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14)], spacing: 14) {
                        ForEach(gradedCourses) { course in
                            Button { selectedCourseID = course.persistentModelID } label: { gradeCard(course) }.buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: selectedCourse == nil ? .infinity : 620)
                if let selectedCourse {
                    gradeDetail(selectedCourse)
                        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func gradeCard(_ course: Course) -> some View {
        let recent = assignments.filter { $0.courseCanvasID == course.canvasID && $0.score != nil }.sorted { ($0.dueAt ?? .distantPast) > ($1.dueAt ?? .distantPast) }.prefix(3)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                CourseBadge(colorHex: course.colorHex, initial: String(course.name.prefix(1)), size: 34)
                VStack(alignment: .leading, spacing: 2) { Text(course.courseCode ?? course.name).font(.system(size: 13, weight: .semibold)); Text(course.instructorName ?? course.termName ?? "Canvas course").font(.system(size: 10.5)).foregroundStyle(.secondary) }
                Spacer()
                Text(course.currentGrade ?? "—").font(.system(size: 20, weight: .medium, design: .serif))
            }
            HStack(alignment: .firstTextBaseline) { Text(course.currentScore.map { String(format: "%.1f", $0) } ?? "—").font(.system(size: 34, design: .serif)); Text("%").font(.system(size: 15)).foregroundStyle(.secondary) }
            ProgressView(value: min(max(course.currentScore ?? 0, 0), 100), total: 100).tint(LecternTheme.accent)
            if recent.isEmpty { Text("Canvas has not returned graded assignments yet.").font(.system(size: 11)).foregroundStyle(.secondary) }
            ForEach(Array(recent)) { assignment in
                HStack { Text(assignment.title).font(.system(size: 11)).lineLimit(1); Spacer(); Text(assignment.grade ?? assignment.score.map { $0.formatted() } ?? "—").font(.system(size: 11, weight: .semibold)) }
            }
        }
        .padding(18).frame(maxWidth: .infinity, minHeight: 250, maxHeight: 250, alignment: .topLeading).studioPanel()
    }

    private func gradeDetail(_ course: Course) -> some View {
        let items = assignments.filter { $0.courseCanvasID == course.canvasID }.sorted { ($0.dueAt ?? .distantFuture) > ($1.dueAt ?? .distantFuture) }
        return VStack(alignment: .leading, spacing: 12) {
            HStack { VStack(alignment: .leading) { Text(course.name).font(.system(size: 17, weight: .semibold, design: .serif)); Text("All Canvas grades").font(.system(size: 11)).foregroundStyle(.secondary) }; Spacer(); Button { selectedCourseID = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        HStack { VStack(alignment: .leading, spacing: 3) { Text(item.title).font(.system(size: 11.5, weight: .medium)).lineLimit(2); Text(item.dueAt?.formatted(date: .abbreviated, time: .omitted) ?? "No due date").font(.system(size: 10)).foregroundStyle(.secondary) }; Spacer(); Text(item.grade ?? item.score.map { $0.formatted() } ?? "—").font(.system(size: 12, weight: .semibold)); Text(item.pointsPossible.map { "/ \($0.formatted())" } ?? "").font(.system(size: 10)).foregroundStyle(.secondary) }.padding(.vertical, 10)
                        Divider()
                    }
                }
            }
        }.padding(18).studioPanel()
    }
}

struct CanvasResourcesView: View {
    private struct ModuleGroup: Identifiable {
        let id: String
        let courseName: String
        let moduleName: String
        let items: [CanvasResource]
    }

    @Environment(\.openURL) private var openURL
    @Environment(CanvasResourceOpener.self) private var resourceOpener
    @Query(sort: \CanvasResource.courseName) private var resources: [CanvasResource]
    let courses: [Course]
    let allowedCourseIDs: Set<Int64>
    @State private var search = ""
    @State private var selectedCourseID: Int64?
    @State private var selectedModuleID: String?
    @State private var selectedKind: String?

    private var courseOptions: [StudioDropdownOption<Int64?>] {
        [StudioDropdownOption(value: nil, title: "All courses")] + courses.compactMap { course in
            course.canvasID.map { StudioDropdownOption(value: Optional($0), title: course.name, subtitle: course.courseCode) }
        }
    }

    private var matchingResources: [CanvasResource] {
        resources.filter { resource in
            guard allowedCourseIDs.contains(resource.courseCanvasID),
                  selectedCourseID == nil || selectedCourseID == resource.courseCanvasID else { return false }
            return search.isEmpty
                || resource.title.localizedCaseInsensitiveContains(search)
                || resource.courseName.localizedCaseInsensitiveContains(search)
                || resource.moduleName.localizedCaseInsensitiveContains(search)
                || resource.kind.localizedCaseInsensitiveContains(search)
        }
    }

    private var moduleGroups: [ModuleGroup] {
        Dictionary(grouping: matchingResources) { resource in
            "\(resource.courseCanvasID)::\(resource.moduleName)"
        }
        .map { key, items in
            let ordered = items.sorted { lhs, rhs in
                lhs.position == rhs.position ? lhs.title < rhs.title : lhs.position < rhs.position
            }
            return ModuleGroup(
                id: key,
                courseName: ordered.first?.courseName ?? "Course",
                moduleName: ordered.first?.moduleName ?? "Module",
                items: ordered
            )
        }
        .sorted { ($0.courseName, $0.moduleName) < ($1.courseName, $1.moduleName) }
    }

    private var selectedModule: ModuleGroup? { moduleGroups.first { $0.id == selectedModuleID } }
    private var visibleGroups: [ModuleGroup] { selectedModule.map { [$0] } ?? moduleGroups }
    private var kinds: [String] { Array(Set(matchingResources.map(\.kind))).sorted() }

    var body: some View {
        StudioPage(title: "Resources", subtitle: "Canvas material organized by course, module, and type") {
            HStack(spacing: 12) {
                StudioDropdown(title: "Course", selection: $selectedCourseID, options: courseOptions, width: 250, icon: "book.closed")
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search resources", text: $search).textFieldStyle(.plain)
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 11)
                .frame(width: 320, height: 34)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(LecternTheme.hairline))
            }

            HStack(spacing: 14) {
                moduleSidebar
                resourceLibrary
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: selectedCourseID) { _, _ in selectedModuleID = nil }
        .onChange(of: search) { _, _ in
            if selectedModuleID.map({ id in !moduleGroups.contains(where: { $0.id == id }) }) == true {
                selectedModuleID = nil
            }
        }
        .alert("Could not open Canvas file", isPresented: .init(
            get: { resourceOpener.errorMessage != nil },
            set: { if !$0 { resourceOpener.clearError() } }
        )) {
            Button("OK", role: .cancel) { resourceOpener.clearError() }
        } message: {
            Text(resourceOpener.errorMessage ?? "")
        }
    }

    private var moduleSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("MODULES").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(moduleGroups.count)").font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
            }
            .padding(14)

            Divider()

            ScrollView {
                LazyVStack(spacing: 5) {
                    moduleButton(id: nil, title: "All resources", subtitle: "\(matchingResources.count) items", icon: "tray.full")
                    ForEach(moduleGroups) { group in
                        moduleButton(
                            id: group.id,
                            title: group.moduleName,
                            subtitle: "\(group.courseName) · \(group.items.count)",
                            icon: "square.stack.3d.up"
                        )
                    }
                }
                .padding(8)
            }
        }
        .frame(width: 260)
        .frame(maxHeight: .infinity)
        .studioPanel()
    }

    private func moduleButton(id: String?, title: String, subtitle: String, icon: String) -> some View {
        let isSelected = selectedModuleID == id
        return Button { selectedModuleID = id } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 12)).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                    Text(subtitle).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .foregroundStyle(isSelected ? LecternTheme.accent : LecternTheme.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(isSelected ? LecternTheme.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var resourceLibrary: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedModule?.moduleName ?? "All resources")
                        .font(.system(size: 17, weight: .semibold, design: .serif))
                    Text(selectedModule?.courseName ?? "Browse every synced Canvas module")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer()
                kindChip(nil, title: "All")
                ForEach(kinds.prefix(5), id: \.self) { kind in kindChip(kind, title: kind) }
            }
            .padding(14)

            Divider()

            if matchingResources.isEmpty {
                ContentUnavailableView("No resources", systemImage: "folder", description: Text("Nothing matches this course and search."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(visibleGroups) { group in
                            let visibleItems = group.items.filter { selectedKind == nil || $0.kind == selectedKind }
                            if !visibleItems.isEmpty { resourceGroup(group, items: visibleItems) }
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .studioPanel()
    }

    private func kindChip(_ kind: String?, title: String) -> some View {
        Button { selectedKind = kind } label: {
            Text(title)
                .font(.system(size: 9.5, weight: .medium))
                .padding(.horizontal, 8).padding(.vertical, 5)
                .foregroundStyle(selectedKind == kind ? LecternTheme.accent : .secondary)
                .background(selectedKind == kind ? LecternTheme.accent.opacity(0.10) : Color.primary.opacity(0.035), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func resourceGroup(_ group: ModuleGroup, items: [CanvasResource]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.moduleName).font(.system(size: 13.5, weight: .semibold))
                    Text(group.courseName).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(items.count) items").font(.system(size: 9.5)).foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()

            ForEach(items) { resource in
                Button {
                    if resource.kind.caseInsensitiveCompare("File") == .orderedSame {
                        let reference = CanvasResourceReference(
                            title: resource.title,
                            moduleName: resource.moduleName,
                            kind: resource.kind,
                            canvasID: resource.canvasID,
                            htmlURL: resource.htmlURL,
                            apiURL: resource.apiURL
                        )
                        Task { await resourceOpener.openFile(reference, key: resource.syncKey) }
                    } else if let url = CanvasResourceDestination.url(
                        kind: resource.kind,
                        canvasID: resource.canvasID,
                        htmlURL: resource.htmlURL,
                        apiURL: resource.apiURL
                    ) {
                        openURL(url)
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: resourceIcon(resource.kind))
                            .font(.system(size: 13)).frame(width: 24, height: 24)
                            .foregroundStyle(LecternTheme.accent)
                            .background(LecternTheme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(resource.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                            Text(resource.kind).font(.system(size: 9.5)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if resourceOpener.openingKey == resource.syncKey {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: resource.kind.caseInsensitiveCompare("File") == .orderedSame ? "eye" : "arrow.up.right")
                                .font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(resourceOpener.openingKey != nil)
                if resource.id != items.last?.id { Divider().padding(.leading, 48) }
            }
        }
        .studioPanel()
    }

    private func resourceIcon(_ kind: String) -> String { switch kind { case "File": "doc.fill"; case "Page": "doc.text"; case "Quiz": "questionmark.circle"; case "Assignment": "checklist"; case "Discussion": "bubble.left.and.bubble.right"; default: "link" } }
}

struct CanvasAnnouncementsView: View {
    @Environment(\.openURL) private var openURL
    @Query(sort: \CanvasAnnouncement.postedAt, order: .reverse) private var announcements: [CanvasAnnouncement]
    let courses: [Course]
    let allowedCourseIDs: Set<Int64>
    @State private var selectedCourseID: Int64?
    @State private var selectedAnnouncementID: Int64?
    private var visible: [CanvasAnnouncement] { announcements.filter { allowedCourseIDs.contains($0.courseCanvasID) && (selectedCourseID == nil || selectedCourseID == $0.courseCanvasID) } }
    private var selected: CanvasAnnouncement? { visible.first { $0.canvasID == selectedAnnouncementID } }
    private var courseOptions: [StudioDropdownOption<Int64?>] {
        [StudioDropdownOption(value: nil, title: "All courses")] + courses.compactMap { course in
            course.canvasID.map { StudioDropdownOption(value: Optional($0), title: course.name, subtitle: course.courseCode) }
        }
    }

    var body: some View {
        StudioPage(title: "Announcements", subtitle: "Complete faculty updates for Fall 2026") {
            HStack {
                StudioDropdown(title: "Course", selection: $selectedCourseID, options: courseOptions, width: 250, icon: "book.closed")
                Spacer()
            }
            HStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if visible.isEmpty { ContentUnavailableView("No announcements", systemImage: "megaphone") }
                        ForEach(visible) { announcement in
                            Button { selectedAnnouncementID = announcement.canvasID } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack { Text(announcement.courseName).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(LecternTheme.accent); Spacer(); Text(announcement.postedAt.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 10)).foregroundStyle(.secondary) }
                                    Text(announcement.title).font(.system(size: 13, weight: .semibold, design: .serif)).lineLimit(2)
                                    Text(announcement.messageHTML?.canvasPlainText ?? "No preview available").font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(3)
                                }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(selectedAnnouncementID == announcement.canvasID ? LecternTheme.accent.opacity(0.10) : LecternTheme.cardFill, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(LecternTheme.hairline))
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(width: 360).padding(14)
                Divider()
                announcementDetail
            }
            .studioPanel()
        }
    }

    @ViewBuilder private var announcementDetail: some View {
        if let selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(selected.courseName.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(LecternTheme.accent)
                    Text(selected.title).font(.system(size: 25, weight: .bold, design: .serif))
                    HStack { Text(selected.authorName ?? "Course faculty"); Text("·"); Text(selected.postedAt.formatted(date: .long, time: .shortened)); Spacer() }.font(.system(size: 11)).foregroundStyle(.secondary)
                    Divider()
                    Text(selected.messageHTML?.canvasPlainText ?? "This announcement has no body.").font(.system(size: 13)).lineSpacing(5).textSelection(.enabled)
                    if let value = selected.htmlURL, let url = URL(string: value) { Button("Open original in Canvas") { openURL(url) }.buttonStyle(.bordered) }
                }.padding(28).frame(maxWidth: 760, alignment: .leading)
            }.frame(maxWidth: .infinity)
        } else { ContentUnavailableView("Select an announcement", systemImage: "megaphone", description: Text("The complete announcement will appear here.")).frame(maxWidth: .infinity, maxHeight: .infinity) }
    }
}

struct CommandStudioAIView: View {
    let courses: [Course]
    @State private var selectedCourseID: PersistentIdentifier?

    private var selectedCourse: Course? { courses.first { $0.persistentModelID == selectedCourseID } ?? courses.first }
    private var courseOptions: [StudioDropdownOption<PersistentIdentifier?>] {
        courses.map { course in
            StudioDropdownOption(value: Optional(course.persistentModelID), title: course.name, subtitle: course.courseCode)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let course = selectedCourse {
                CourseSynthesisView(
                    course: course,
                    availableCourses: courses,
                    selectedCourseID: $selectedCourseID,
                    onClose: {}
                )
                .id(course.persistentModelID)
            } else {
                ContentUnavailableView("Create or sync a course first", systemImage: "sparkles")
            }
        }
    }
}

struct StudioPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) { Text(title).font(.system(size: 28, weight: .bold, design: .serif)).foregroundStyle(LecternTheme.ink); Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary) }
            content
        }
        .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(LecternTheme.panelFill)
    }
}

private struct EventAgendaRow: View {
    let event: CanvasEvent
    var tint: Color = LecternTheme.accent
    var showsPersonalBadge = false
    private var isAllDay: Bool {
        guard showsPersonalBadge, event.endAt == nil else { return false }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: event.startAt)
        return parts.hour == 0 && parts.minute == 0
    }
    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading) {
                Text(isAllDay ? "All day" : event.startAt.formatted(date: .omitted, time: .shortened)).font(.system(size: 12, weight: .semibold).monospacedDigit())
                if let end = event.endAt { Text(end.formatted(date: .omitted, time: .shortened)).font(.system(size: 10)).foregroundStyle(.secondary) }
                else if showsPersonalBadge && !isAllDay { Text("Personal").font(.system(size: 10)).foregroundStyle(.secondary) }
            }.frame(width: 78, alignment: .leading)
            Rectangle().fill(tint).frame(width: 3, height: 42)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(event.title).font(.system(size: 13, weight: .semibold))
                    if showsPersonalBadge { StatusChip("Personal", tint) }
                }
                Text([event.courseName, event.locationName].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if showsPersonalBadge {
                Image(systemName: "pencil").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }.padding(14).studioPanel()
    }
}

private struct AssignmentAgendaRow: View {
    let assignment: CanvasAssignment
    var body: some View { HStack(spacing: 14) { Image(systemName: assignment.isComplete ? "checkmark.circle.fill" : "checklist").font(.system(size: 17)).foregroundStyle(assignment.isComplete ? LecternTheme.successTint : LecternTheme.warningTint).frame(width: 78); VStack(alignment: .leading, spacing: 3) { Text(assignment.title).font(.system(size: 13, weight: .semibold)); Text("\(assignment.courseName) · \(assignmentDetail(assignment))").font(.system(size: 11)).foregroundStyle(.secondary) }; Spacer() }.padding(14).studioPanel() }
}

private extension View {
    func studioPanel() -> some View {
        background(LecternTheme.cardFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(LecternTheme.hairline))
    }
}
