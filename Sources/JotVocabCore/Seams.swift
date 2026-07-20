import Foundation

// The four platform-injection seams the package exposes (design §1). Everything
// platform-specific — the ASR engine's rescore output, the common-word list
// loading, logging, and the storage directory — crosses one of these so the
// core stays a pure Foundation island.

// MARK: - Seam 1 · engine-neutral rescore input

/// One proposed replacement, mirrored from FluidAudio's `RescoringResult` so the
/// gate never imports FluidAudio. Each app maps its engine output into this at
/// the call site.
public struct RescoreProposal: Sendable, Equatable {
    public let originalWord: String
    public let replacementWord: String?
    public let shouldReplace: Bool
    public let replacementScore: Float?
    public let originalScore: Float

    public init(originalWord: String, replacementWord: String?, shouldReplace: Bool,
                replacementScore: Float?, originalScore: Float) {
        self.originalWord = originalWord
        self.replacementWord = replacementWord
        self.shouldReplace = shouldReplace
        self.replacementScore = replacementScore
        self.originalScore = originalScore
    }
}

/// The rescorer's full output, mirrored from FluidAudio's `RescoreOutput`.
public struct RescoreOutput: Sendable, Equatable {
    public let text: String
    public let replacements: [RescoreProposal]
    public let wasModified: Bool

    public init(text: String, replacements: [RescoreProposal], wasModified: Bool) {
        self.text = text
        self.replacements = replacements
        self.wasModified = wasModified
    }
}

/// Per-word/subword timing the gate reads to protect confident words.
///
/// NOTE (deviation from design §1 prose): the design says "reuse JotTextPipeline's
/// shape", but that `TokenTiming` carries `token`/`startTime`/`endTime` and no
/// confidence. The gate reads `token` + `confidence` (never the times), so this
/// is a distinct value type in a distinct module. The two `TokenTiming`s are
/// intentionally different and both are qualified by module at the (few) call
/// sites that consume each — exactly the mapping pattern ParagraphSegmenter uses.
public struct TokenTiming: Sendable, Equatable {
    public let token: String
    public let confidence: Float

    public init(token: String, confidence: Float) {
        self.token = token
        self.confidence = confidence
    }
}

// MARK: - Seam 2 · common-word list loading

/// Loads the high-frequency word set for a language's resource name (bundle-
/// specific). The gate takes a plain resource string (e.g. `"common-words-es"`)
/// — never a FluidAudio-linked `LanguageChoice` — and asks the provider.
public protocol CommonWordsProvider: Sendable {
    /// Everyday-word set for `resource` (`<resource>.txt`). `nil` resource ⇒ no
    /// list ships for that language ⇒ empty set (the guard degrades to
    /// plausibility/confidence, still safe).
    func words(forResource resource: String?) -> Set<String>
}

/// Default provider, package-resource-backed (owner decision 2026-07-16: the
/// per-language dictionaries live in the shared repo). Lazily loads each list
/// from `Bundle.module` and caches it; only the language(s) actually dictated in
/// are ever read into memory. Manual `NSLock` serialization mirrors the iOS
/// `CommonWords` cache (the compiler can't see the lock invariant).
///
/// **Fails LOUDLY (review finding 1).** A `nil` resource is an intentional
/// "no list ships for this language" and returns `[]` silently. But a *non-nil*
/// resource whose `.txt` is missing/unreadable is a BUG: it silently disables
/// the common-word brake — the exact over-correction class this subsystem
/// exists to prevent (every name becomes Jamy). That case emits a
/// `.vocabularyGate` diagnostic (once per resource) via the injected sink so the
/// miss is visible instead of invisible. Production callers should construct
/// this with their app sink; `.shared` uses a no-op (a test asserts the loud
/// path with a capturing sink and a bogus resource name).
public final class BundledCommonWordsProvider: CommonWordsProvider, @unchecked Sendable {
    public static let shared = BundledCommonWordsProvider()

    private let lock = NSLock()
    private var cache: [String: Set<String>] = [:]
    private let diagnostics: DiagnosticsSink

    public init(diagnostics: DiagnosticsSink = NoopDiagnosticsSink()) {
        self.diagnostics = diagnostics
    }

    public func words(forResource resource: String?) -> Set<String> {
        guard let resource else { return [] }   // nil = intentional no-guard, silent
        lock.lock()
        if let cached = cache[resource] { lock.unlock(); return cached }
        let loaded = Self.load(resource)
        let set = loaded ?? []
        cache[resource] = set
        lock.unlock()
        // Emit OUTSIDE the lock (don't call an arbitrary sink while holding it).
        // `loaded == nil` distinguishes missing/unreadable (loud) from a
        // legitimately-empty-but-present list (`Set([])`, silent).
        if loaded == nil {
            diagnostics.record(
                category: .vocabularyGate,
                message: "common-words resource '\(resource)' missing/unreadable — common-word guard DISABLED for it",
                metadata: ["resource": resource])
        }
        return set
    }

    /// `nil` ⇒ the resource is missing or unreadable (loud path). A present but
    /// empty file returns an empty `Set` (success, silent).
    private static func load(_ resource: String) -> Set<String>? {
        guard
            let url = Bundle.module.url(
                forResource: resource, withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return nil
        }
        return Set(text.split(separator: "\n").map { String($0).lowercased() })
    }
}

// MARK: - Seam 3 · diagnostics

/// Diagnostic categories the moved code emits. Package-owned (design decision:
/// a small typed enum, not a bare `String`, preserving the type safety the
/// app's category gives today). The moved code emits exactly these two; the
/// app-side adapter maps them onto its own `DiagnosticsLog.Category`.
public enum DiagnosticsCategory: Sendable, Equatable {
    /// Gate decision trace + provenance commits.
    case vocabularyGate
    /// A vocab-data persistence refusal (e.g. corrections.json failed to decode,
    /// so the store refuses to overwrite it).
    case vocabularySaveFailed
}

/// Replaces the two logger kinds the moved files used (`os.Logger` and
/// `DiagnosticsLog.record`). Direct `os.Logger` lines in the moved code are
/// dropped (redundant with the sink); the app-side adapter re-adds `os.log` if
/// it wants it. Tests capture into an array.
public protocol DiagnosticsSink: Sendable {
    func record(category: DiagnosticsCategory, message: String, metadata: [String: String])
}

/// A sink that discards everything — the default for callers that don't wire
/// diagnostics (and a convenient test/no-op).
public struct NoopDiagnosticsSink: DiagnosticsSink {
    public init() {}
    public func record(category: DiagnosticsCategory, message: String, metadata: [String: String]) {}
}
