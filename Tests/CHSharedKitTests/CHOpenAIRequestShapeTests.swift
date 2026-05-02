import Testing
import Foundation
@testable import CHSharedKit

// MARK: - 2.9.3 — OpenAI request-shape regression pin
//
// Greps `CHOpenAIProvider.swift` to assert it never reintroduces
// `max_tokens` on chat/completions request bodies. GPT-5 / GPT-5.4 /
// GPT-5.5 / o-series reasoning models reject `max_tokens` outright
// with `unsupported_parameter`; the kit must always send
// `max_completion_tokens`. This is a source-level test rather than a
// runtime test because we don't want CI to depend on an OpenAI key.

@Suite("CHOpenAIProvider request shape")
struct CHOpenAIRequestShapeTests {

    @Test("OpenAI provider source uses max_completion_tokens, never max_tokens")
    func providerUsesMaxCompletionTokens() throws {
        let url = providerSourceURL()
        let source = try String(contentsOf: url, encoding: .utf8)

        // Strip block comments so the docstring that mentions the
        // legacy parameter (for context) doesn't trigger the failure.
        let stripped = stripBlockComments(source)

        // Strip line comments — same reason; docstring lines also
        // reference `max_tokens` as the deprecated form.
        let codeOnly = stripped
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                if let range = line.range(of: "//") { return String(line[..<range.lowerBound]) }
                return String(line)
            }
            .joined(separator: "\n")

        // Chat-completions bodies must use the new parameter…
        #expect(codeOnly.contains("\"max_completion_tokens\""),
                "CHOpenAIProvider source must send max_completion_tokens on every chat/completions body")
        // …and must not use the legacy one.
        #expect(!codeOnly.contains("\"max_tokens\""),
                "CHOpenAIProvider source must NOT send max_tokens (rejected by GPT-5+/o-series)")
    }

    @Test("Provider source does not send temperature (reasoning models reject it)")
    func providerOmitsTemperature() throws {
        let url = providerSourceURL()
        let source = try String(contentsOf: url, encoding: .utf8)
        let stripped = stripBlockComments(source)
        let codeOnly = stripped
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                if let range = line.range(of: "//") { return String(line[..<range.lowerBound]) }
                return String(line)
            }
            .joined(separator: "\n")
        #expect(!codeOnly.contains("\"temperature\""),
                "CHOpenAIProvider source must not set temperature explicitly — reasoning models reject it.")
    }

    // MARK: - Helpers

    private func providerSourceURL() -> URL {
        // Walk up from the test file (using #filePath which is reliably
        // absolute, unlike #file which can be relative under some test
        // runners) until we hit a directory containing Package.swift —
        // that's the kit's package root. From there, descend into
        // Sources/CHSharedKit/. Robust to nested layouts and reliable
        // for both `swift test` and Xcode package test runs.
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fm = FileManager.default
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("Package.swift")
            if fm.fileExists(atPath: candidate.path) {
                return dir
                    .appendingPathComponent("Sources/CHSharedKit/CHOpenAIProvider.swift")
            }
            dir = dir.deletingLastPathComponent()
        }
        // Fallback — assumes the conventional layout.
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CHSharedKit/CHOpenAIProvider.swift")
    }

    private func stripBlockComments(_ s: String) -> String {
        var result = ""
        var i = s.startIndex
        while i < s.endIndex {
            if i < s.index(before: s.endIndex),
               s[i] == "/", s[s.index(after: i)] == "*" {
                // Skip until closing */.
                var j = s.index(i, offsetBy: 2)
                while j < s.endIndex {
                    if j < s.index(before: s.endIndex),
                       s[j] == "*", s[s.index(after: j)] == "/" {
                        j = s.index(j, offsetBy: 2)
                        break
                    }
                    j = s.index(after: j)
                }
                i = j
                continue
            }
            result.append(s[i])
            i = s.index(after: i)
        }
        return result
    }
}
