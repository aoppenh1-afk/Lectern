import Foundation
import Observation
import Security

enum TranscriptionProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    case local
    case deepgram
    case googleGemini
    case antigravityCLI
    case assemblyAI
    case modulate
    case mistral
    case groq
    case elevenLabs

    var id: String { rawValue }

    var requiresAPIKey: Bool {
        self != .local && self != .antigravityCLI
    }
}

enum TranscriptionSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case local
    case external
    case askEachTime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: return "On this Mac"
        case .external: return "External provider"
        case .askEachTime: return "Ask each time"
        }
    }
}

enum BuiltInTranscriptionModel: String, Codable, CaseIterable, Identifiable, Sendable {
    case parakeet = "parakeet-tdt-0.6b-v3-coreml"
    case whisper = "whisper-large-v3-q5_0"
    case antigravity = "gemini-3.8-flash-high"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .parakeet: return "Parakeet TDT 0.6B"
        case .whisper: return "Whisper Large v3"
        case .antigravity: return "Antigravity ACP"
        }
    }

    var subtitle: String {
        switch self {
        case .parakeet: return "On-device · best for English lectures"
        case .whisper: return "On-device · best for English and Hebrew shiurim"
        case .antigravity: return "Google Antigravity · official ACP connection"
        }
    }

    var modelInfo: String {
        switch self {
        case .parakeet: return "mweinbach1/parakeet-tdt-0.6b-v3-coreml"
        case .whisper: return "whisper.cpp/large-v3-q5_0"
        case .antigravity: return rawValue
        }
    }

    var usesAntigravity: Bool { self == .antigravity }

    static func automatic(for language: LectureLanguage) -> BuiltInTranscriptionModel {
        language == .hebrewEnglish ? .whisper : .parakeet
    }

    static func resolve(_ storedValue: String?, language: LectureLanguage) -> BuiltInTranscriptionModel {
        guard let storedValue, !storedValue.isEmpty else { return automatic(for: language) }
        if let match = BuiltInTranscriptionModel(rawValue: storedValue)
            ?? allCases.first(where: { $0.modelInfo == storedValue || $0.id == storedValue }) {
            return match
        }
        if isAntigravityModelChoice(storedValue) {
            return .antigravity
        }
        return automatic(for: language)
    }

    /// The model selected through ACP. The built-in Antigravity option and the
    /// retired Gemini 3.7 Flash High default both resolve to the current High model.
    static func resolvedAntigravityModelID(_ storedValue: String?) -> String {
        guard let storedValue, !storedValue.isEmpty else {
            return AntigravityACPClient.transcriptionModelID
        }
        if storedValue == antigravity.id
            || storedValue.contains("3.7")
            || storedValue.caseInsensitiveCompare(antigravity.title) == .orderedSame
            || storedValue.caseInsensitiveCompare("Gemini 3.7 Flash (High)") == .orderedSame
            || storedValue.caseInsensitiveCompare("Gemini 3.8 Flash (High)") == .orderedSame {
            return AntigravityACPClient.transcriptionModelID
        }
        if isAntigravityModelChoice(storedValue),
           !storedValue.lowercased().hasPrefix("gemini ") {
            return storedValue
        }
        return AntigravityACPClient.transcriptionModelID
    }

    static func isAntigravityModelChoice(_ storedValue: String) -> Bool {
        if storedValue == AntigravityACPClient.modelID
            || storedValue == antigravity.id
            || storedValue.caseInsensitiveCompare(antigravity.title) == .orderedSame {
            return true
        }
        let normalized = storedValue.lowercased()
        if normalized.hasPrefix("gemini-") { return true }
        if normalized.range(of: #"^gemini\s+\d+(?:\.\d+)?\s+(flash|pro)(\s+\((low|medium|high)\))?$"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }
}

/// Picks the transcriber for a new or retried job. An explicit Settings model
/// such as Gemini 3.8 Flash High wins over the Hebrew→whisper automatic default.
enum TranscriptionJobPlan: Equatable, Sendable {
    case askEachTime
    case local(BuiltInTranscriptionModel)
    case external

    var usesWhisperCLI: Bool {
        self == .local(.whisper)
    }

    var usesAntigravityACPClient: Bool {
        if case .local(let model) = self { return model.usesAntigravity }
        return false
    }

    static func resolve(
        preferenceSource: TranscriptionSource,
        preferenceBuiltInModelID: String?,
        lectureSource: TranscriptionSource?,
        lectureModelID: String?,
        language: LectureLanguage
    ) -> TranscriptionJobPlan {
        let source = lectureSource ?? preferenceSource
        switch source {
        case .askEachTime:
            return .askEachTime
        case .external:
            return .external
        case .local:
            let storedModelID: String?
            if lectureSource == .local {
                storedModelID = lectureModelID ?? preferenceBuiltInModelID
            } else {
                storedModelID = preferenceBuiltInModelID
            }
            return .local(BuiltInTranscriptionModel.resolve(storedModelID, language: language))
        }
    }

    func progressSubtitle(connectionName: String? = nil) -> String {
        switch self {
        case .askEachTime:
            return "Choose a transcriber to continue."
        case .local(.parakeet):
            return "Parakeet is working through your recording locally."
        case .local(.whisper):
            return "whisper.cpp is working through your recording locally."
        case .local(.antigravity):
            return "\(AntigravityACPClient.transcriptionDisplayName) is transcribing through Antigravity ACP."
        case .external:
            if let connectionName, !connectionName.isEmpty {
                return "Uploading audio only to \(connectionName). Study generation stays on its current agent."
            }
            return "Uploading audio to your selected API connection."
        }
    }
}

enum TranscriptionProcessingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard
    case batch

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum TranscriptionLanguageMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case fixed

    var id: String { rawValue }
}

enum TimestampGranularity: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case segment
    case word

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum ConnectionCostTier: String, Codable, CaseIterable, Identifiable, Sendable {
    case free
    case included
    case paid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: return "Free tier"
        case .included: return "Credit / included"
        case .paid: return "Paid"
        }
    }

    var isPaid: Bool { self == .paid }
}

struct TranscriptionCapabilities: Codable, Hashable, Sendable {
    var supportsPrerecorded = true
    var supportsStreaming = false
    var supportsAsyncPolling = false
    var supportsAutomaticLanguageDetection = true
    var supportedLanguageCodes: Set<String>?
    var supportsCodeSwitching = false
    var supportsDiarization = false
    var supportsSegmentTimestamps = true
    var supportsWordTimestamps = false
    var supportsWordConfidence = false
    var supportsLanguagePerSegment = false
    var supportsLanguagePerWord = false
    var supportsKeyterms = false
    var maxKeyterms: Int?
    var supportsContextPrompt = false
    var maxContextPromptLength: Int?
    var supportsStandardMode = true
    var supportsBatchMode = false
    var supportsFreeTier = false
    var freeTierDescription: String?
    var privacyWarning: String?
    var commercialUseWarning: String?
    var maxUploadBytes: Int64?
    var maxAudioDurationMilliseconds: Int64?
}

struct TranscriptionModelDescriptor: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let capabilities: TranscriptionCapabilities
}

struct TranscriptionProviderDescriptor: Identifiable, Sendable {
    let id: TranscriptionProviderID
    let name: String
    let shortName: String
    let assetName: String
    let tintHex: String
    let summary: String
    let models: [TranscriptionModelDescriptor]
}

enum TranscriptionProviderCatalog {
    static let providers: [TranscriptionProviderDescriptor] = [
        .init(
            id: .local,
            name: "Built-in transcription",
            shortName: "MAC",
            assetName: "TranscriptionGemini",
            tintHex: "5D6B62",
            summary: "Choose either on-device speech recognition or the signed-in Antigravity ACP runtime.",
            models: BuiltInTranscriptionModel.allCases.map { model in
                .init(
                    id: model.id,
                    title: model.title,
                    subtitle: model.subtitle,
                    capabilities: .init(
                        supportsCodeSwitching: model != .parakeet,
                        supportsDiarization: model.usesAntigravity,
                        supportsSegmentTimestamps: true,
                        supportsContextPrompt: model != .parakeet,
                        privacyWarning: model.usesAntigravity
                            ? "The recording is sent to Google as a native audio block through Antigravity ACP."
                            : nil
                    )
                )
            }
        ),
        .init(
            id: .deepgram,
            name: "Deepgram",
            shortName: "DG",
            assetName: "TranscriptionDeepgram",
            tintHex: "13EF95",
            summary: "Fast dedicated speech recognition with strong timing metadata.",
            models: [
                .init(id: "nova-3", title: "Nova-3", subtitle: "Recommended for balanced lectures", capabilities: .init(
                    supportsStreaming: true, supportedLanguageCodes: ["en", "he"], supportsCodeSwitching: true,
                    supportsDiarization: true, supportsWordTimestamps: true, supportsWordConfidence: true,
                    supportsLanguagePerWord: true, supportsKeyterms: true, maxKeyterms: 100,
                    supportsFreeTier: true, freeTierDescription: "New-account credit may be available."
                ))
            ]
        ),
        .init(
            id: .googleGemini,
            name: "Google Gemini",
            shortName: "G",
            assetName: "TranscriptionGemini",
            tintHex: "4285F4",
            summary: "Flexible multilingual transcription with structured segment output.",
            models: [
                .init(id: "gemini-3.8-flash", title: "Gemini 3.8 Flash", subtitle: "Best free-tier quality candidate", capabilities: .init(
                    supportsCodeSwitching: true, supportsDiarization: true, supportsSegmentTimestamps: true,
                    supportsContextPrompt: true, maxContextPromptLength: 8_000, supportsFreeTier: true,
                    freeTierDescription: "Quota varies by project and account.",
                    privacyWarning: "Google may use free-tier content to improve its products. Paid-tier terms differ."
                )),
                .init(id: "gemini-3.5-flash-lite", title: "Gemini 3.5 Flash-Lite", subtitle: "Lower-cost fallback", capabilities: .init(
                    supportsCodeSwitching: true, supportsDiarization: true, supportsSegmentTimestamps: true,
                    supportsContextPrompt: true, maxContextPromptLength: 8_000, supportsFreeTier: true,
                    freeTierDescription: "Quota varies by project and account.",
                    privacyWarning: "Google may use free-tier content to improve its products. Paid-tier terms differ."
                ))
            ]
        ),
        .init(
            id: .antigravityCLI,
            name: "Antigravity ACP",
            shortName: "AG",
            assetName: "TranscriptionGemini",
            tintHex: "4285F4",
            summary: "Gemini 3.8 Flash High through Google's official Antigravity ACP runtime.",
            models: [
                .init(
                    id: AntigravityACPClient.transcriptionModelID,
                    title: AntigravityACPClient.transcriptionDisplayName,
                    subtitle: "Official ACP runtime · isolated Google sign-in",
                    capabilities: .init(
                        supportsCodeSwitching: true,
                        supportsDiarization: true,
                        supportsSegmentTimestamps: true,
                        supportsContextPrompt: true,
                        maxContextPromptLength: 8_000,
                        freeTierDescription: "Uses the Google account signed into Lectern's Antigravity ACP profile.",
                        privacyWarning: "The recording is sent to Google as native audio through Antigravity ACP."
                    )
                )
            ]
        ),
        .init(
            id: .assemblyAI,
            name: "AssemblyAI",
            shortName: "AA",
            assetName: "TranscriptionAssemblyAI",
            tintHex: "6C47FF",
            summary: "A strong mixed English and Hebrew choice with speaker labels.",
            models: [
                .init(id: "universal-3-5-pro", title: "Universal-3.5 Pro", subtitle: "Recommended for shiur accuracy", capabilities: .init(
                    supportsAsyncPolling: true, supportedLanguageCodes: ["en", "he"], supportsCodeSwitching: true,
                    supportsDiarization: true, supportsWordTimestamps: true, supportsWordConfidence: true,
                    supportsKeyterms: true, maxKeyterms: 1_000, supportsContextPrompt: true,
                    supportsFreeTier: true, freeTierDescription: "Included usage may be available."
                )),
                .init(id: "universal-2", title: "Universal-2", subtitle: "Compatibility model", capabilities: .init(
                    supportsAsyncPolling: true, supportsDiarization: true, supportsWordTimestamps: true,
                    supportsWordConfidence: true, supportsKeyterms: true, maxKeyterms: 1_000
                ))
            ]
        ),
        .init(
            id: .modulate,
            name: "Modulate",
            shortName: "M",
            assetName: "TranscriptionModulate",
            tintHex: "F15A3D",
            summary: "Low-cost multilingual batch transcription with diarized utterances.",
            models: [
                .init(id: "multilingual-batch", title: "Multilingual Batch", subtitle: "Lowest-cost multilingual preset", capabilities: .init(
                    supportsCodeSwitching: true, supportsDiarization: true, supportsLanguagePerSegment: true,
                    supportsKeyterms: true, supportsBatchMode: true, supportsFreeTier: true,
                    freeTierDescription: "Included allocation may depend on account.", maxUploadBytes: 100_000_000
                )),
                .init(id: "english-vfast", title: "English VFast", subtitle: "Fast English endpoint", capabilities: .init(
                    supportedLanguageCodes: ["en"], supportsWordTimestamps: true
                )),
                .init(id: "multilingual-vfast", title: "Multilingual VFast", subtitle: "Fast multilingual endpoint", capabilities: .init(
                    supportsCodeSwitching: true, supportsWordTimestamps: true
                ))
            ]
        ),
        .init(
            id: .mistral,
            name: "Mistral",
            shortName: "M",
            assetName: "TranscriptionMistral",
            tintHex: "FF7000",
            summary: "Economical English lecture transcription, especially in Batch mode.",
            models: [
                .init(id: "voxtral-mini-2602", title: "Voxtral Mini Transcribe 2", subtitle: "Pinned model", capabilities: .init(
                    supportedLanguageCodes: ["en", "fr", "de", "es", "it", "pt", "nl", "hi", "ar", "ru", "zh", "ja", "ko"],
                    supportsDiarization: true, supportsWordTimestamps: true, supportsContextPrompt: true,
                    maxContextPromptLength: 100, supportsBatchMode: true, supportsFreeTier: true,
                    freeTierDescription: "Monthly credits may be available.", maxAudioDurationMilliseconds: 10_800_000
                )),
                .init(id: "voxtral-mini-latest", title: "Voxtral Mini Latest", subtitle: "Provider-managed alias", capabilities: .init(
                    supportedLanguageCodes: ["en", "fr", "de", "es", "it", "pt", "nl", "hi", "ar", "ru", "zh", "ja", "ko"],
                    supportsDiarization: true, supportsWordTimestamps: true, supportsContextPrompt: true,
                    maxContextPromptLength: 100, supportsBatchMode: true, supportsFreeTier: true,
                    freeTierDescription: "Monthly credits may be available.", maxAudioDurationMilliseconds: 10_800_000
                ))
            ]
        ),
        .init(
            id: .groq,
            name: "Groq",
            shortName: "GQ",
            assetName: "TranscriptionGroq",
            tintHex: "F55036",
            summary: "Very low-cost Whisper transcription with a useful free allowance.",
            models: [
                .init(id: "whisper-large-v3-turbo", title: "Whisper Large v3 Turbo", subtitle: "Recommended", capabilities: .init(
                    supportsWordTimestamps: true, supportsContextPrompt: true, maxContextPromptLength: 224,
                    supportsBatchMode: true, supportsFreeTier: true, freeTierDescription: "Rate-limited free usage may be available."
                )),
                .init(id: "whisper-large-v3", title: "Whisper Large v3", subtitle: "Quality alternative", capabilities: .init(
                    supportsWordTimestamps: true, supportsContextPrompt: true, maxContextPromptLength: 224,
                    supportsBatchMode: true, supportsFreeTier: true, freeTierDescription: "Rate-limited free usage may be available."
                ))
            ]
        ),
        .init(
            id: .elevenLabs,
            name: "ElevenLabs",
            shortName: "11",
            assetName: "TranscriptionElevenLabs",
            tintHex: "111111",
            summary: "Detailed word timing and speaker labels across many languages.",
            models: [
                .init(id: "scribe_v2", title: "Scribe v2", subtitle: "Accuracy reference", capabilities: .init(
                    supportsStreaming: true, supportsCodeSwitching: true, supportsDiarization: true,
                    supportsWordTimestamps: true, supportsKeyterms: true, maxKeyterms: 1_000,
                    supportsFreeTier: true, freeTierDescription: "Free usage is noncommercial.",
                    commercialUseWarning: "The free plan does not grant commercial-use rights."
                ))
            ]
        )
    ]

    static func provider(_ id: TranscriptionProviderID) -> TranscriptionProviderDescriptor? {
        providers.first { $0.id == id }
    }

    static func model(provider id: TranscriptionProviderID, modelID: String) -> TranscriptionModelDescriptor? {
        provider(id)?.models.first { $0.id == modelID }
    }

    static func capabilities(provider id: TranscriptionProviderID, modelID: String) -> TranscriptionCapabilities {
        model(provider: id, modelID: modelID)?.capabilities ?? conservativeCapabilities
    }

    static let conservativeCapabilities = TranscriptionCapabilities(
        supportsPrerecorded: true,
        supportsAutomaticLanguageDetection: false,
        supportsSegmentTimestamps: false
    )
}

struct TranscriptionConnection: Identifiable, Codable, Hashable, Sendable {
    static let builtInAntigravityID = UUID(uuidString: "A17A0000-0000-4000-8000-000000000001")!

    var id: UUID
    var displayName: String
    var provider: TranscriptionProviderID
    var modelID: String
    var credentialReference: String
    var enabled: Bool
    var languageMode: TranscriptionLanguageMode
    var languageCode: String?
    var diarizationEnabled: Bool
    var timestampGranularity: TimestampGranularity
    var processingMode: TranscriptionProcessingMode
    var costTier: ConnectionCostTier
    var cloudUploadConsent: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        displayName: String,
        provider: TranscriptionProviderID,
        modelID: String,
        credentialReference: String = UUID().uuidString,
        enabled: Bool = true,
        languageMode: TranscriptionLanguageMode = .automatic,
        languageCode: String? = nil,
        diarizationEnabled: Bool = false,
        timestampGranularity: TimestampGranularity = .segment,
        processingMode: TranscriptionProcessingMode = .standard,
        costTier: ConnectionCostTier = .free,
        cloudUploadConsent: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.provider = provider
        self.modelID = modelID
        self.credentialReference = credentialReference
        self.enabled = enabled
        self.languageMode = languageMode
        self.languageCode = languageCode
        self.diarizationEnabled = diarizationEnabled
        self.timestampGranularity = timestampGranularity
        self.processingMode = processingMode
        self.costTier = costTier
        self.cloudUploadConsent = cloudUploadConsent
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var capabilities: TranscriptionCapabilities {
        TranscriptionProviderCatalog.capabilities(provider: provider, modelID: modelID)
    }

    static func builtInAntigravity(modelID: String? = nil) -> TranscriptionConnection {
        .init(
            id: builtInAntigravityID,
            displayName: "Antigravity ACP",
            provider: .antigravityCLI,
            modelID: modelID.flatMap { $0.isEmpty ? nil : $0 } ?? AntigravityACPClient.transcriptionModelID,
            diarizationEnabled: true,
            timestampGranularity: .segment,
            costTier: .free,
            cloudUploadConsent: true
        )
    }
}

struct TranscriptionPreferencesSnapshot: Codable, Sendable {
    var source: TranscriptionSource = .local
    var builtInModelID: String?
    var defaultConnectionID: UUID?
    var fallbackConnectionIDs: [UUID] = []
    var allowFallbackProviders = false
    var freeConnectionsOnly = false
    var neverFallbackFromFreeToPaid = true
    var askBeforePaidFallback = true
    var allowCloudFallbackAfterLocalFailure = false
}

@MainActor
@Observable
final class TranscriptionPreferences {
    static let settingsKey = "transcription.connections.v1"
    static let policyKey = "transcription.policy.v1"

    var connections: [TranscriptionConnection] = [] { didSet { persistConnections() } }
    var source: TranscriptionSource = .local { didSet { persistPolicy() } }
    var builtInModelID: String? { didSet { persistPolicy() } }
    var defaultConnectionID: UUID? { didSet { persistPolicy() } }
    var fallbackConnectionIDs: [UUID] = [] { didSet { persistPolicy() } }
    var allowFallbackProviders = false { didSet { persistPolicy() } }
    var freeConnectionsOnly = false { didSet { persistPolicy() } }
    var neverFallbackFromFreeToPaid = true { didSet { persistPolicy() } }
    var askBeforePaidFallback = true { didSet { persistPolicy() } }
    var allowCloudFallbackAfterLocalFailure = false { didSet { persistPolicy() } }

    private var isLoading = true
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.settingsKey),
           let decoded = try? JSONDecoder().decode([TranscriptionConnection].self, from: data) {
            connections = decoded
        }
        if let data = defaults.data(forKey: Self.policyKey),
           let policy = try? JSONDecoder().decode(TranscriptionPreferencesSnapshot.self, from: data) {
            source = policy.source
            builtInModelID = Self.sanitizeBuiltInModelID(policy.builtInModelID)
            defaultConnectionID = policy.defaultConnectionID
            fallbackConnectionIDs = policy.fallbackConnectionIDs
            allowFallbackProviders = policy.allowFallbackProviders
            freeConnectionsOnly = policy.freeConnectionsOnly
            neverFallbackFromFreeToPaid = policy.neverFallbackFromFreeToPaid
            askBeforePaidFallback = policy.askBeforePaidFallback
            allowCloudFallbackAfterLocalFailure = policy.allowCloudFallbackAfterLocalFailure
        }
        isLoading = false
        sanitize()
    }

    var defaultConnection: TranscriptionConnection? {
        let allowed: (TranscriptionConnection) -> Bool = { connection in
            connection.enabled && (!self.freeConnectionsOnly || !connection.costTier.isPaid)
        }
        if let configured = connection(id: defaultConnectionID), allowed(configured) {
            return configured
        }
        return connections.first(where: allowed)
    }

    func connection(id: UUID?) -> TranscriptionConnection? {
        guard let id else { return nil }
        return connections.first { $0.id == id }
    }

    func upsert(_ connection: TranscriptionConnection) {
        var updated = connection
        updated.updatedAt = Date()
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[index] = updated
        } else {
            connections.append(updated)
        }
        if defaultConnectionID == nil { defaultConnectionID = updated.id }
        if !fallbackConnectionIDs.contains(updated.id) { fallbackConnectionIDs.append(updated.id) }
    }

    func remove(_ connection: TranscriptionConnection) throws {
        if connection.provider.requiresAPIKey {
            try KeychainCredentialStore.remove(reference: connection.credentialReference)
        }
        connections.removeAll { $0.id == connection.id }
        fallbackConnectionIDs.removeAll { $0 == connection.id }
        if defaultConnectionID == connection.id {
            defaultConnectionID = connections.first(where: \.enabled)?.id
        }
    }

    func moveFallback(fromOffsets: IndexSet, toOffset: Int) {
        let moving = fromOffsets.sorted().map { fallbackConnectionIDs[$0] }
        for index in fromOffsets.sorted(by: >) {
            fallbackConnectionIDs.remove(at: index)
        }
        let removedBeforeDestination = fromOffsets.filter { $0 < toOffset }.count
        fallbackConnectionIDs.insert(contentsOf: moving, at: max(0, toOffset - removedBeforeDestination))
    }

    func fallbackPlan(startingWith selected: TranscriptionConnection) -> [TranscriptionConnection] {
        guard selected.enabled,
              !freeConnectionsOnly || !selected.costTier.isPaid else {
            return []
        }
        var ordered = [selected]
        guard allowFallbackProviders else { return ordered }
        for id in fallbackConnectionIDs where id != selected.id {
            guard let candidate = connection(id: id), candidate.enabled else { continue }
            if freeConnectionsOnly && candidate.costTier.isPaid { continue }
            if neverFallbackFromFreeToPaid,
               let previous = ordered.last,
               !previous.costTier.isPaid,
               candidate.costTier.isPaid {
                continue
            }
            ordered.append(candidate)
        }
        return ordered
    }

    func snapshot() -> TranscriptionPreferencesSnapshot {
        .init(
            source: source,
            builtInModelID: builtInModelID,
            defaultConnectionID: defaultConnectionID,
            fallbackConnectionIDs: fallbackConnectionIDs,
            allowFallbackProviders: allowFallbackProviders,
            freeConnectionsOnly: freeConnectionsOnly,
            neverFallbackFromFreeToPaid: neverFallbackFromFreeToPaid,
            askBeforePaidFallback: askBeforePaidFallback,
            allowCloudFallbackAfterLocalFailure: allowCloudFallbackAfterLocalFailure
        )
    }

    static func sanitizeBuiltInModelID(_ modelID: String?) -> String? {
        guard let modelID, !modelID.isEmpty else { return nil }
        if modelID.contains("3.7") {
            return modelID.replacingOccurrences(of: "3.7", with: "3.8")
        }
        return modelID
    }

    private func sanitize() {
        if let id = builtInModelID, id.contains("3.7") {
            builtInModelID = Self.sanitizeBuiltInModelID(id)
            persistPolicy()
        }
        let valid = Set(connections.map(\.id))
        fallbackConnectionIDs = fallbackConnectionIDs.filter(valid.contains)
        if let defaultConnectionID, !valid.contains(defaultConnectionID) {
            self.defaultConnectionID = connections.first(where: \.enabled)?.id
        }
    }

    private func persistConnections() {
        guard !isLoading, let data = try? JSONEncoder().encode(connections) else { return }
        defaults.set(data, forKey: Self.settingsKey)
    }

    private func persistPolicy() {
        guard !isLoading, let data = try? JSONEncoder().encode(snapshot()) else { return }
        defaults.set(data, forKey: Self.policyKey)
    }
}

enum KeychainCredentialStore {
    private static let service = "com.lectern.transcription-api"

    static func save(_ secret: String, reference: String) throws {
        let value = Data(secret.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
        ]
        SecItemDelete(base as CFDictionary)
        var query = base
        query[kSecValueData as String] = value
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func read(reference: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainError(status: status)
        }
        return value
    }

    static func remove(reference: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    static func maskedSuffix(reference: String) -> String? {
        guard let secret = try? read(reference: reference), !secret.isEmpty else { return nil }
        return "•••• " + secret.suffix(4)
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        if status == errSecItemNotFound { return "No API key is stored for this connection." }
        return "Keychain error (\(status))."
    }
}

struct NormalizedTranscriptionSegment: Codable, Hashable, Sendable {
    var id = UUID()
    var startMilliseconds: Int64?
    var endMilliseconds: Int64?
    var text: String
    var speakerID: String?
    var languageCode: String?
    var confidence: Double?
}

struct NormalizedTranscriptionWord: Codable, Hashable, Sendable {
    var startMilliseconds: Int64?
    var endMilliseconds: Int64?
    var text: String
    var speakerID: String?
    var languageCode: String?
    var confidence: Double?
}

struct ProviderTranscriptInfo: Codable, Hashable, Sendable {
    var connectionID: UUID
    var provider: TranscriptionProviderID
    var requestedModelID: String
    var resolvedModelID: String?
    var providerJobID: String?
    var attemptNumber: Int
    var processingMode: TranscriptionProcessingMode
    var completedAt: Date
}

struct TranscriptionResult: Codable, Sendable {
    var id = UUID()
    var text: String
    var segments: [NormalizedTranscriptionSegment]
    var words: [NormalizedTranscriptionWord]?
    var detectedLanguages: [String]
    var providerInfo: ProviderTranscriptInfo
    var audioDurationMilliseconds: Int64?
    var warnings: [String]
}

enum TranscriptionErrorCode: String, Codable, Sendable {
    case invalidCredentials
    case permissionDenied
    case quotaExceeded
    case rateLimited
    case unsupportedModel
    case unsupportedLanguage
    case unsupportedMedia
    case fileTooLarge
    case audioTooLong
    case networkUnavailable
    case providerUnavailable
    case timeout
    case acceptedStateUnknown
    case malformedResponse
    case contentRejected
    case cancelled
    case unknown
}

struct ExternalTranscriptionError: LocalizedError, Codable, Sendable {
    var code: TranscriptionErrorCode
    var retryable: Bool
    var fallbackEligible: Bool
    var retryAfter: Date?
    var userMessage: String
    var safeDiagnostics: String?
    var providerStatusCode: Int?
    var providerRequestID: String?

    var errorDescription: String? { userMessage }
}

enum LocalCheckpointRecovery {
    static let legacyAmbiguousUploadMessage =
        "The upload may have been accepted, so Lectern stopped before retrying or using a paid fallback."

    static func isNearlyComplete(
        markdown: String,
        durationSeconds: Double,
        source: TranscriptionSource?,
        failureMessage: String?
    ) -> Bool {
        guard source == .local,
              failureMessage?.contains(legacyAmbiguousUploadMessage) == true,
              durationSeconds > 0,
              markdown.count >= 100 else {
            return false
        }

        let timestampPattern = /\[(\d+):(\d{2})\]/
        let lastTimestamp = markdown.matches(of: timestampPattern).last.map { match in
            Double(match.output.1)! * 60 + Double(match.output.2)!
        }
        return lastTimestamp.map { $0 >= durationSeconds * 0.95 } ?? false
    }
}

enum TranscriptionJobState: String, Codable, Sendable {
    case queued
    case preparing
    case uploading
    case submitted
    case processing
    case waitingForRetry
    case waitingForFallback
    case completed
    case failed
    case cancelled
}

struct TranscriptionAttemptRecord: Codable, Sendable {
    var connectionID: UUID
    var provider: TranscriptionProviderID
    var requestedModelID: String
    var resolvedModelID: String?
    var providerJobID: String?
    var submittedAt: Date?
    var lastPolledAt: Date?
    var retryCount = 0
    var error: ExternalTranscriptionError?
    var acceptedStateUnknown = false
}

struct PersistentTranscriptionJob: Codable, Identifiable, Sendable {
    var id = UUID()
    var recordingPath: String
    var sourceAudioHash: String
    var state: TranscriptionJobState
    var selectedConnectionID: UUID
    var fallbackPlanSnapshot: [UUID]
    var policySnapshot: TranscriptionPreferencesSnapshot
    var currentAttemptIndex = 0
    var attempts: [TranscriptionAttemptRecord] = []
    var completedResult: TranscriptionResult? = nil
    var createdAt = Date()
    var updatedAt = Date()
    var completedAt: Date?
}

actor TranscriptionJobStore {
    private let fileURL: URL
    private var jobs: [PersistentTranscriptionJob]

    init(fileManager: FileManager = .default, fileURL overrideURL: URL? = nil) {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = overrideURL?.deletingLastPathComponent()
            ?? support.appendingPathComponent("Lectern", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = overrideURL ?? directory.appendingPathComponent("TranscriptionJobs.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([PersistentTranscriptionJob].self, from: data) {
            jobs = decoded
        } else {
            jobs = []
        }
    }

    func recoverableJob(
        recordingPath: String,
        sourceAudioHash: String,
        includeCompleted: Bool
    ) -> PersistentTranscriptionJob? {
        jobs.last {
            guard $0.recordingPath == recordingPath,
                  $0.sourceAudioHash == sourceAudioHash else {
                return false
            }
            switch $0.state {
            case .failed, .cancelled:
                return false
            case .completed:
                return includeCompleted && $0.completedResult != nil
            default:
                return true
            }
        }
    }

    func job(id: UUID) -> PersistentTranscriptionJob? {
        jobs.first { $0.id == id }
    }

    func upsert(_ job: PersistentTranscriptionJob) {
        var updated = job
        updated.updatedAt = Date()
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = updated
        } else {
            jobs.append(updated)
        }
        persist()
    }

    func update(id: UUID, state: TranscriptionJobState, providerJobID: String?) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = state
        jobs[index].updatedAt = Date()
        if let providerJobID, jobs[index].attempts.indices.contains(jobs[index].currentAttemptIndex) {
            jobs[index].attempts[jobs[index].currentAttemptIndex].providerJobID = providerJobID
            jobs[index].attempts[jobs[index].currentAttemptIndex].lastPolledAt = Date()
        }
        persist()
    }

    func completedJobs(recordingPath: String) -> [PersistentTranscriptionJob] {
        jobs.filter { $0.recordingPath == recordingPath && $0.state == .completed }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
