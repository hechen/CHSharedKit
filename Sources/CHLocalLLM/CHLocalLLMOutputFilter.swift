import Foundation

// MARK: - CHLocalLLMOutputFilter
//
// 2.19.8: one answer, whatever the model. Offline models differ in ways a
// chat UI must not see:
//
// - Reasoning. Qwen3 thinks unless its template is told not to (the provider
//   passes `enable_thinking: false`, and Qwen3 may still emit an empty
//   `<think></think>`). DeepSeek-R1 distills always reason, and their
//   template pre-fills the opening `<think>`, so the reply starts inside the
//   reasoning with only a closing tag.
// - Turn markers. When a model's configured EOS misses its own end-of-turn
//   token (seen with Phi), `<|end|>` leaks and the model goes on to write the
//   user's next turn.
//
// The filter streams: it holds back only what could be the start of a tag,
// drops reasoning blocks, and stops at the first end-of-turn marker. A reply
// that never leaves its reasoning falls back to the reasoning text rather
// than coming back empty.

struct CHLocalLLMOutputFilter {
    static let reasoningTags: [(open: String, close: String)] = [
        ("<think>", "</think>"),
        ("<thinking>", "</thinking>"),
        ("<reasoning>", "</reasoning>"),
    ]

    /// End-of-turn and role markers. Anything from the first one on is not
    /// part of the answer.
    static let stopMarkers: [String] = [
        "<|im_end|>", "<|im_start|>",
        "<|eot_id|>", "<|start_header_id|>",
        "<|end|>", "<|user|>", "<|assistant|>", "<|system|>",
        "<|endoftext|>",
        "<end_of_turn>", "<start_of_turn>",
        "<｜end▁of▁sentence｜>", "<｜User｜>", "<｜Assistant｜>",
        "</s>",
    ]

    /// Closing tag awaited while inside a reasoning block.
    private var awaitedClose: String?
    private var pending = ""
    private var reasoning = ""
    private var emittedAny = false
    /// True once an end-of-turn marker was seen; callers stop generating.
    private(set) var isFinished = false

    /// - Parameter startsInsideReasoning: the chat template pre-fills an
    ///   opening reasoning tag (see ``templatePrefillsReasoning(_:)``).
    init(startsInsideReasoning: Bool = false) {
        awaitedClose = startsInsideReasoning ? "</think>" : nil
    }

    /// Feeds one streamed chunk; returns the text that can be shown now.
    mutating func feed(_ chunk: String) -> String {
        guard !isFinished else { return "" }
        pending += chunk
        return drain(final: false)
    }

    /// Flushes what was held back at the end of generation.
    mutating func finish() -> String {
        guard !isFinished else { return "" }
        var out = drain(final: true)
        if awaitedClose != nil {
            // Generation ended inside reasoning.
            reasoning += pending
            pending = ""
            awaitedClose = nil
            if !emittedAny { out += Self.trimmedLeading(reasoning) }
        } else {
            out += emit(pending)
            pending = ""
        }
        isFinished = true
        return out
    }

    /// Filters a complete response.
    static func clean(_ text: String, startsInsideReasoning: Bool = false) -> String {
        var filter = CHLocalLLMOutputFilter(startsInsideReasoning: startsInsideReasoning)
        let body = filter.feed(text)
        return (body + filter.finish()).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a chat template's generation prompt opens a reasoning block
    /// the model is expected to close (DeepSeek-R1 distills). Templates with
    /// an `enable_thinking` switch are turned off instead, and templates that
    /// never mention `<think>` do not reason.
    static func templatePrefillsReasoning(_ template: String?) -> Bool {
        guard let template, template.contains("<think>") else { return false }
        if template.contains("enable_thinking") { return false }
        // The generation prompt ends in an opening tag with no closing one.
        let compact = template.replacingOccurrences(of: " ", with: "")
        return compact.contains("<think>\\n'}}") || compact.contains("<think>\\n\"}}")
            || compact.contains("<think>'}}") || compact.contains("<think>\"}}")
            || compact.contains("<think>\n'}}") || compact.contains("<think>\n\"}}")
    }

    /// 2.19.11: whether a chat template accepts a system message. Gemma's
    /// raises "System role not supported"; MLX then renders without it, so
    /// the model never saw its instructions (persona, length, reply
    /// language). Callers fold the instructions into the user turn instead.
    static func templateAcceptsSystemRole(_ template: String?) -> Bool {
        guard let template else { return true }
        if template.contains("System role not supported") { return false }
        return template.contains("system")
    }

    // MARK: Streaming core

    private mutating func drain(final: Bool) -> String {
        var out = ""
        while !pending.isEmpty, !isFinished {
            if let close = awaitedClose {
                if let range = pending.range(of: close) {
                    reasoning += pending[..<range.lowerBound]
                    pending.removeSubrange(..<range.upperBound)
                    awaitedClose = nil
                    continue
                }
                // Keep only what could be the start of the closing tag.
                let keep = final ? 0 : Self.partialSuffixLength(of: pending, matching: [close])
                reasoning += pending.dropLast(keep)
                pending = String(pending.suffix(keep))
                return out
            }
            let opens = Self.reasoningTags.compactMap { tag in
                pending.range(of: tag.open).map { (range: $0, tag: tag) }
            }
            let firstOpen = opens.min { $0.range.lowerBound < $1.range.lowerBound }
            let firstStop = Self.stopMarkers
                .compactMap { pending.range(of: $0) }
                .min { $0.lowerBound < $1.lowerBound }
            // A stray closing tag with no opening one ends a reasoning block
            // the template opened without saying so. Text already shown
            // cannot be taken back (hence the template hint), but the tag
            // itself never shows.
            let strayClose = Self.reasoningTags
                .compactMap { pending.range(of: $0.close) }
                .min { $0.lowerBound < $1.lowerBound }

            if let stop = firstStop,
               firstOpen.map({ stop.lowerBound <= $0.range.lowerBound }) ?? true,
               strayClose.map({ stop.lowerBound <= $0.lowerBound }) ?? true {
                out += emit(String(pending[..<stop.lowerBound]))
                pending = ""
                isFinished = true
                return out
            }
            if let close = strayClose,
               firstOpen.map({ close.lowerBound < $0.range.lowerBound }) ?? true {
                if emittedAny {
                    out += emit(String(pending[..<close.lowerBound]))
                } else {
                    reasoning += pending[..<close.lowerBound]
                }
                pending.removeSubrange(..<close.upperBound)
                continue
            }
            if let open = firstOpen {
                out += emit(String(pending[..<open.range.lowerBound]))
                pending.removeSubrange(..<open.range.upperBound)
                awaitedClose = open.tag.close
                continue
            }
            // No complete tag: hold back a possible partial one.
            let candidates = Self.reasoningTags.flatMap { [$0.open, $0.close] } + Self.stopMarkers
            let keep = final ? 0 : Self.partialSuffixLength(of: pending, matching: candidates)
            out += emit(String(pending.dropLast(keep)))
            pending = String(pending.suffix(keep))
            return out
        }
        return out
    }

    private mutating func emit(_ text: String) -> String {
        let shown = emittedAny ? text : Self.trimmedLeading(text)
        if !shown.isEmpty { emittedAny = true }
        return shown
    }

    private static func trimmedLeading(_ text: String) -> String {
        String(text.drop { $0.isWhitespace || $0.isNewline })
    }

    /// Length of the longest suffix of `text` that is a proper prefix of one
    /// of `tags`.
    static func partialSuffixLength(of text: String, matching tags: [String]) -> Int {
        guard let lastOpen = text.lastIndex(where: { $0 == "<" }) else { return 0 }
        let tail = text[lastOpen...]
        guard tags.contains(where: { $0.count > tail.count && $0.hasPrefix(tail) }) else { return 0 }
        return tail.count
    }
}
