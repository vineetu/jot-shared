import Foundation

/// ONE normalization for every correction-learning identity key (V2-2,
/// 2026-07-14). EXACT-string semantics under: NFC precompose → case-fold →
/// collapse internal whitespace runs → trim OUTER punctuation only.
/// Internal punctuation and word boundaries are PRESERVED (can't ≠ cant,
/// "a part" ≠ "apart") — the round-2 review killed skeleton-canonical keys
/// for exactly those collisions. Used by CorrectionStore keys, provenance
/// mapping keys, and the ask policy's prior lookups so the three can
/// never disagree about which pair a verdict belongs to. For every key any
/// prior build could persist (ASCII, single-spaced, punct-trimmed), the
/// output is IDENTICAL to the old per-file normalizers — so existing data
/// needs no migration; a legacy-key fallback in the provenance ledger
/// covers the rare pre-existing untrimmed mapping keys.
///
/// **Locale-invariant lowercasing (package invariant, not a seam).** The
/// no-argument `String.lowercased()` used here is locale-*independent*
/// (Unicode default case-folding): `"I".lowercased()` → `"i"`, never the
/// Turkish/Azeri dotless `"ı"`. This must fold identically on every machine so
/// stored keys stay cross-platform-identical. It is byte-compatible with every
/// key any shipped build persisted; the value of pinning it (see
/// `correction_key_normalize.json`, incl. the explicit Turkish-`I` row) is
/// regression-proofing — a future refactor to `lowercased(with: .current)` must
/// fail the fixture rather than silently corrupt keys in the field.
public enum CorrectionKey {
    public static func normalize(_ s: String) -> String {
        let nfc = s.precomposedStringWithCanonicalMapping.lowercased()
        let collapsed = nfc.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: " .,!?;:\"'()"))
    }

    /// The ONE `"<originalWord>|<term>"` membership-key shape the stores and
    /// publishers use for keyboard-suppression / merge-asked / prior lookups.
    /// **Asymmetric on purpose:** the original side is fully `normalize`d (NFC +
    /// case-fold + whitespace-collapse + outer-punct-trim), the term side is
    /// only `.lowercased()` — exactly what `CorrectionStore.keyboardSuppressedPairs()`
    /// / `mergeAskedPairs()` and `AskPolicy` produce today. Mac's `AppDelegate`
    /// duplicates a DIFFERENT, older normalize inline; routing it through this
    /// helper at Stage 1 is what keeps ask-suppression from silently breaking
    /// under mismatched key rules. Locked by `pair_key.json`.
    public static func pairKey(originalWord: String, term: String) -> String {
        "\(normalize(originalWord))|\(term.lowercased())"
    }
}
