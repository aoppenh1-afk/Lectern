import SwiftUI

// MARK: - Paper design system
//
// Principles (UI prototype round, Aug 2026 -- see prototype/ui-paper-redesign):
// - Warm paper surfaces carry the window; content cards are white-on-paper with hairlines.
// - One switchable brand accent (moss default); status colors stay semantic.
// - Serif display type for document titles; sans for chrome.
// - Hierarchy via ink opacity tiers, never extra hues.
// - Separation via hairlines and surface steps, not shadows.

enum LecternTheme {
    // MARK: Accent (switchable brand accent, tuned per appearance)

    static var accent: Color {
        switch UserDefaults.standard.string(forKey: "appearance.accent") ?? "moss" {
        case "blue":
            return adaptive(light: NSColor(srgbRed: 0.184, green: 0.420, blue: 0.929, alpha: 1),   // #2F6BED
                            dark: NSColor(srgbRed: 0.424, green: 0.620, blue: 1.000, alpha: 1))    // #6C9EFF
        case "plum":
            return adaptive(light: NSColor(srgbRed: 0.486, green: 0.290, blue: 0.451, alpha: 1),   // #7C4A73
                            dark: NSColor(srgbRed: 0.788, green: 0.576, blue: 0.753, alpha: 1))    // #C993C0
        case "graphite":
            return adaptive(light: NSColor(srgbRed: 0.290, green: 0.300, blue: 0.320, alpha: 1),   // #4A4D52
                            dark: NSColor(srgbRed: 0.780, green: 0.790, blue: 0.810, alpha: 1))    // #C7C9CF
        default: // moss
            return adaptive(light: NSColor(srgbRed: 0.290, green: 0.459, blue: 0.329, alpha: 1),   // #4A7554
                            dark: NSColor(srgbRed: 0.545, green: 0.722, blue: 0.576, alpha: 1))    // #8BB893
        }
    }

    static let accentChoices: [(id: String, name: String)] = [
        ("moss", "Moss"),
        ("blue", "Ocean"),
        ("plum", "Plum"),
        ("graphite", "Graphite"),
    ]

    // MARK: Paper surfaces (adaptive light/dark)

    static var paper: Color {
        adaptive(light: NSColor(srgbRed: 0.988, green: 0.984, blue: 0.973, alpha: 1),   // #FCFBF8
                 dark: NSColor(srgbRed: 0.110, green: 0.110, blue: 0.115, alpha: 1))
    }

    static var paperDeep: Color {
        adaptive(light: NSColor(srgbRed: 0.965, green: 0.957, blue: 0.937, alpha: 1),   // #F6F4EF
                 dark: NSColor(srgbRed: 0.085, green: 0.085, blue: 0.090, alpha: 1))
    }

    static var cardFill: Color {
        adaptive(light: NSColor(srgbRed: 1.000, green: 1.000, blue: 1.000, alpha: 0.72),
                 dark: NSColor(srgbRed: 1.000, green: 1.000, blue: 1.000, alpha: 0.05))
    }

    /// Deep green-black ink for serif display type on paper.
    static var ink: Color {
        adaptive(light: NSColor(srgbRed: 0.160, green: 0.190, blue: 0.160, alpha: 1),   // #293029
                 dark: NSColor(srgbRed: 0.920, green: 0.925, blue: 0.930, alpha: 1))
    }

    // MARK: Semantic pipeline colors (adaptive light/dark)

    static let recordTint = adaptive(light: NSColor(srgbRed: 0.898, green: 0.282, blue: 0.302, alpha: 1),   // #E5484D
                                      dark: NSColor(srgbRed: 1.000, green: 0.388, blue: 0.412, alpha: 1))    // #FF6369

    static let processingTint = adaptive(light: NSColor(srgbRed: 0.486, green: 0.361, blue: 0.749, alpha: 1), // #7C5CBF
                                          dark: NSColor(srgbRed: 0.655, green: 0.545, blue: 0.878, alpha: 1))   // #A78BE0

    static let successTint = adaptive(light: NSColor(srgbRed: 0.180, green: 0.490, blue: 0.310, alpha: 1),  // #2E7D4F
                                      dark: NSColor(srgbRed: 0.400, green: 0.753, blue: 0.541, alpha: 1))   // #66C08A

    static let warningTint = adaptive(light: NSColor(srgbRed: 0.718, green: 0.475, blue: 0.122, alpha: 1),  // #B7791F
                                      dark: NSColor(srgbRed: 0.878, green: 0.706, blue: 0.361, alpha: 1))   // #E0B45C

    /// Muted academic palette assigned to new courses.
    static let coursePalette = [
        "#5E81AC", "#BF6B5A", "#7A9471", "#C08A3E",
        "#906FA6", "#4E9B94", "#B05E77", "#77864B",
    ]

    // MARK: Geometry

    static let chipRadius: CGFloat = 4
    static let controlRadius: CGFloat = 8
    static let cardRadius: CGFloat = 12
    static let sheetRadius: CGFloat = 14

    /// Reading column width for documents (transcripts, notes).
    static let readingWidth: CGFloat = 680

    // MARK: Legacy surfaces & ink

    static var hairline: Color { Color.primary.opacity(0.10) }
    static var surfaceFill: Color { Color.primary.opacity(0.04) }
    static var subtleFill: Color { Color.primary.opacity(0.055) }

    static func statusTint(for status: LectureStatus) -> Color {
        switch status {
        case .recording: return recordTint
        case .recorded: return accent
        case .transcribing: return processingTint
        case .ready: return successTint
        case .failed: return warningTint
        }
    }

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    // MARK: Motion budget

    static let standardAnimation = Animation.easeOut(duration: 0.18)
    static let completionSpring = Animation.spring(response: 0.3, dampingFraction: 0.7)
}

// MARK: - Color helpers

extension Color {
    func darkened(by amount: Double) -> Color {
        guard amount > 0 else { return self }
        return Color(.sRGB,
                     red: max(0, redComponent * (1 - amount)),
                     green: max(0, greenComponent * (1 - amount)),
                     blue: max(0, blueComponent * (1 - amount)),
                     opacity: 1)
    }

    private var redComponent: Double { components.0 }
    private var greenComponent: Double { components.1 }
    private var blueComponent: Double { components.2 }

    var components: (Double, Double, Double, Double) {
        #if canImport(AppKit)
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor.white
        return (Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent), Double(ns.alphaComponent))
        #else
        return (0, 0, 0, 1)
        #endif
    }
}

// MARK: - Components

/// Small flat badge carrying a course's tint and initial.
struct CourseBadge: View {
    let colorHex: String
    let initial: String
    var size: CGFloat = 24

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Color(hex: colorHex).opacity(0.16))
            .overlay(
                Text(initial)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(Color(hex: colorHex).darkened(by: 0.08))
            )
            .frame(width: size, height: size)
    }
}

/// Quiet status pill: tinted fill, tinted label, rounded rect (not capsule).
struct StatusChip: View {
    let icon: String?
    let text: String
    let tint: Color
    var pulsing = false

    init(_ text: String, _ tint: Color, icon: String? = nil, pulsing: Bool = false) {
        self.text = text
        self.tint = tint
        self.icon = icon
        self.pulsing = pulsing
    }

    /// Legacy positional initializer retained for call-site brevity.
    init(_ icon: String, _ text: String, _ tint: Color) {
        self.init(text, tint, icon: icon)
    }

    var body: some View {
        HStack(spacing: 4) {
            if pulsing {
                Circle()
                    .fill(tint)
                    .frame(width: 5, height: 5)
                    .symbolEffect(.pulse)
            } else if let icon {
                Image(systemName: icon)
                    .font(.system(size: 8, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: LecternTheme.chipRadius, style: .continuous))
    }
}

/// Plain metadata line: secondary caption with monospaced digits.
struct MetaText: View {
    let parts: [String]

    init(_ parts: [String]) {
        self.parts = parts.filter { !$0.isEmpty }
    }

    var body: some View {
        Text(parts.joined(separator: "  ·  "))
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// Tracked uppercase micro-label used as a section header.
struct SectionLabel: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.tertiary)
    }
}

/// Flat content card: stepped surface fill plus hairline border. No shadow.
struct SurfaceCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LecternTheme.cardFill, in: RoundedRectangle(cornerRadius: LecternTheme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: LecternTheme.cardRadius, style: .continuous)
                    .strokeBorder(LecternTheme.hairline, lineWidth: 1)
            )
    }
}

/// Calm empty state: quiet glyph, one line of copy, one action.
struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
                .frame(width: 64, height: 64)
                .background(Color.primary.opacity(0.045), in: Circle())

            VStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 300)
            }

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - Course subject icon

extension Course {
    /// SF Symbol representing the course's subject, matched by name keywords.
    var subjectSymbol: String {
        let name = name.lowercased()
        if name.contains("bio") { return "leaf" }
        if name.contains("chem") { return "testtube.2" }
        if name.contains("physic") { return "atom" }
        if name.contains("psych") { return "brain.head.profile" }
        if name.contains("histor") { return "building.columns" }
        if name.contains("algebra") || name.contains("calcul") || name.contains("math") { return "function" }
        if name.contains("econom") { return "chart.line.uptrend.xyaxis" }
        if name.contains("geo") { return "globe" }
        if name.contains("art") { return "paintpalette" }
        if name.contains("music") { return "music.note" }
        if name.contains("literat") || name.contains("english") || name.contains("writing") { return "text.book.closed" }
        if name.contains("spanish") || name.contains("french") || name.contains("language") { return "character.bubble" }
        if name.contains("computer") || name.contains("coding") || name.contains("programming") { return "chevron.left.forwardslash.chevron.right" }
        return "book.closed"
    }
}

// MARK: - Typing indicator

/// iMessage-style "assistant is working" indicator: three dots that bounce
/// in sequence (left, middle, right) and loop until removed from the view
/// hierarchy. Each dot runs the same ease-in-out bounce with a staggered
/// start delay so the wave reads left-to-right.
struct TypingIndicatorView: View {
    var dotDiameter: CGFloat = 7
    var spacing: CGFloat = 5

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<3, id: \.self) { index in
                TypingDot(delay: Double(index) * 0.18, diameter: dotDiameter)
            }
        }
        .accessibilityLabel("Assistant is typing")
    }
}

private struct TypingDot: View {
    let delay: Double
    let diameter: CGFloat

    @State private var bounce = false

    var body: some View {
        Circle()
            .fill(Color.secondary)
            .frame(width: diameter, height: diameter)
            .offset(y: bounce ? -4.5 : 0)
            .opacity(bounce ? 1.0 : 0.35)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 0.42)
                        .repeatForever(autoreverses: true)
                        .delay(delay)
                ) {
                    bounce = true
                }
            }
    }
}

// MARK: - Chat composer
//
// Shared prompt-bar styling used by the lecture and course chat composers:
// a tall rounded container with a focus ring, borderless menu buttons split
// by hairline dividers, and a round send/stop button.

struct ComposerContainer: ViewModifier {
    var focused: Bool

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LecternTheme.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(
                        focused ? LecternTheme.accent.opacity(0.55) : LecternTheme.hairline,
                        lineWidth: focused ? 1.5 : 1
                    )
            )
            .shadow(
                color: focused ? LecternTheme.accent.opacity(0.10) : Color.black.opacity(0.05),
                radius: 12, y: 4
            )
            .animation(LecternTheme.standardAnimation, value: focused)
    }
}

extension View {
    func composerContainer(focused: Bool = false) -> some View {
        modifier(ComposerContainer(focused: focused))
    }
}

/// Borderless dropdown button for the composer toolbar (model, thinking).
struct ComposerMenuButton<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: Content

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                content
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .medium))
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(hovered ? LecternTheme.ink : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// Thin vertical separator between composer toolbar menus.
struct ComposerDivider: View {
    var body: some View {
        Rectangle()
            .fill(LecternTheme.hairline)
            .frame(width: 1, height: 20)
    }
}

/// Round send/stop button: muted when idle, accent when ready, a high
/// contrast circle with a stop glyph while responding.
struct ComposerSendButton: View {
    let canSend: Bool
    let isResponding: Bool
    let send: () -> Void
    let cancel: () -> Void

    @State private var hovered = false

    var body: some View {
        Button {
            if isResponding { cancel() } else { send() }
        } label: {
            Image(systemName: isResponding ? "stop.fill" : "arrow.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(iconColor)
                .frame(width: 34, height: 34)
                .background(Circle().fill(circleFill))
                .scaleEffect(hovered && interactive ? 1.06 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(!interactive)
        .help(isResponding ? "Stop response" : "Send")
        .onHover { hovered = $0 }
        .animation(LecternTheme.standardAnimation, value: interactive)
        .animation(LecternTheme.standardAnimation, value: isResponding)
    }

    private var interactive: Bool { canSend || isResponding }

    private var circleFill: Color {
        if isResponding { return .primary }
        if canSend { return LecternTheme.accent }
        return Color.secondary.opacity(0.25)
    }

    private var iconColor: Color {
        if isResponding { return Color(nsColor: .textBackgroundColor) }
        return .white
    }
}

/// Drops a redundant trailing "(…)" thinking suffix from a model display
/// name when the thinking picker is shown separately (e.g.
/// "Gemini 3.8 Flash (Low)" -> "Gemini 3.8 Flash").
func ComposerShortModelLabel(_ label: String) -> String {
    guard let open = label.lastIndex(of: "("),
          label.hasSuffix(")"),
          open > label.startIndex else { return label }
    let prefix = label[..<open].trimmingCharacters(in: .whitespaces)
    return prefix.isEmpty ? label : String(prefix)
}

// MARK: - Floating-chrome plumbing (pill, popover only)

struct GlassPanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.glassEffect(.regular, in: .rect(cornerRadius: LecternTheme.sheetRadius))
    }
}

extension View {
    /// Liquid Glass surface for chrome-less floating windows (pill, popovers).
    func glassPanel() -> some View {
        modifier(GlassPanelModifier())
    }

    /// Prominent filled button using the Liquid Glass button style when available.
    func prominentAction() -> some View {
        buttonStyle(.glassProminent)
    }
}
