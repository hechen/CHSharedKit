import Testing
@testable import CHLocalLLM

/// 2.19.8 — every offline model's reply reaches the app as a plain answer.
@Suite("Local model output filter")
struct CHLocalLLMOutputFilterTests {
    /// Streams `text` in chunks of `size` characters, the way a tokenizer
    /// splits tags across tokens.
    private func streamed(_ text: String, size: Int, startsInsideReasoning: Bool = false) -> String {
        var filter = CHLocalLLMOutputFilter(startsInsideReasoning: startsInsideReasoning)
        var out = ""
        var rest = Substring(text)
        while !rest.isEmpty, !filter.isFinished {
            out += filter.feed(String(rest.prefix(size)))
            rest = rest.dropFirst(size)
        }
        return out + filter.finish()
    }

    private let answer = "Your training load is lower than usual this week."

    @Test("Plain replies pass through unchanged (Qwen 2.5, Llama, Gemma)", arguments: [1, 3, 7, 1000])
    func plain(size: Int) {
        #expect(streamed(answer, size: size) == answer)
        #expect(streamed("Use a 2 < 3 ratio and <b>bold</b> text.", size: size) == "Use a 2 < 3 ratio and <b>bold</b> text.")
    }

    @Test("Qwen3 reasoning is removed, including an empty block", arguments: [1, 2, 5, 1000])
    func qwen3(size: Int) {
        #expect(streamed("<think>\nThe user asks about load.\n</think>\n\n" + answer, size: size) == answer)
        #expect(streamed("<think>\n\n</think>\n\n" + answer, size: size) == answer)
    }

    @Test("DeepSeek-R1 replies start inside reasoning the template opened", arguments: [1, 4, 1000])
    func deepSeekPrefilled(size: Int) {
        let raw = "Okay, let me think about the volume.\n</think>\n\n" + answer
        #expect(streamed(raw, size: size, startsInsideReasoning: true) == answer)
        // Without the template hint, a whole reply is still cleaned; a
        // stream cannot take back text already shown, but never shows the tag.
        #expect(CHLocalLLMOutputFilter.clean(raw) == answer)
        #expect(!streamed(raw, size: size).contains("</think>"))
        #expect(streamed(raw, size: size).hasSuffix(answer))
    }

    @Test("A reply that never leaves its reasoning falls back to the reasoning")
    func unterminatedReasoning() {
        #expect(streamed("<think>Train two more sets.", size: 3) == "Train two more sets.")
        #expect(CHLocalLLMOutputFilter.clean("Train two more sets.", startsInsideReasoning: true) == "Train two more sets.")
    }

    @Test("End-of-turn markers end the answer (Phi, Llama, Gemma, ChatML)", arguments: [
        "<|end|><|user|>What about legs?", "<|eot_id|><|start_header_id|>user", "<end_of_turn>\n<start_of_turn>user",
        "<|im_end|>\n<|im_start|>user", "</s>",
    ])
    func stopMarkers(tail: String) {
        for size in [1, 3, 1000] {
            var filter = CHLocalLLMOutputFilter()
            var out = ""
            for chunk in (answer + tail).chunked(size) where !filter.isFinished { out += filter.feed(chunk) }
            out += filter.finish()
            #expect(out == answer, "chunk size \(size)")
            #expect(filter.isFinished)
        }
    }

    @Test("Instructions reach models whose template has no system role (Gemma)")
    func systemRole() {
        let gemma = "{{ bos_token }}{% if messages[0]['role'] == 'system' %}{{ raise_exception('System role not supported') }}{% endif %}"
        let chatML = "{% for message in messages %}{{'<|im_start|>' + message['role'] }}{% endfor %}{% if messages[0]['role'] == 'system' %}{% endif %}"
        #expect(!CHLocalLLMOutputFilter.templateAcceptsSystemRole(gemma))
        #expect(CHLocalLLMOutputFilter.templateAcceptsSystemRole(chatML))
        #expect(CHLocalLLMOutputFilter.templateAcceptsSystemRole(nil))
        let folded = CHLocalLLMProvider.turn(prompt: "How's my week?", systemPrompt: "Reply in German.", template: gemma)
        #expect(folded.instructions == nil)
        #expect(folded.prompt == "Reply in German.\n\nHow's my week?")
        let kept = CHLocalLLMProvider.turn(prompt: "How's my week?", systemPrompt: "Reply in German.", template: chatML)
        #expect(kept.instructions == "Reply in German.")
        #expect(kept.prompt == "How's my week?")
    }

    @Test("Chat templates that pre-fill reasoning are recognized")
    func templateDetection() {
        let deepSeek = "{% if add_generation_prompt %}{{'<｜Assistant｜><think>\\n'}}{% endif %}"
        let qwen3 = "{%- if enable_thinking is defined and enable_thinking is false %}{{- '<think>\\n\\n</think>\\n\\n' }}{%- endif %}"
        let llama = "{{- '<|start_header_id|>assistant<|end_header_id|>\\n\\n' }}"
        #expect(CHLocalLLMOutputFilter.templatePrefillsReasoning(deepSeek))
        #expect(!CHLocalLLMOutputFilter.templatePrefillsReasoning(qwen3))
        #expect(!CHLocalLLMOutputFilter.templatePrefillsReasoning(llama))
        #expect(!CHLocalLLMOutputFilter.templatePrefillsReasoning(nil))
    }
}

private extension String {
    func chunked(_ size: Int) -> [String] {
        var chunks: [String] = []
        var rest = Substring(self)
        while !rest.isEmpty {
            chunks.append(String(rest.prefix(size)))
            rest = rest.dropFirst(size)
        }
        return chunks
    }
}
