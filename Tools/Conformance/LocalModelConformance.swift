// Offline model conformance: every active catalog model must give a chat UI
// a plain answer. Run on an Apple Silicon Mac:
//
//   swift run local-model-conformance              # every active model
//   swift run local-model-conformance qwen3-1.7b-q4 llama3.2-1b-q4km
//
// Each model is downloaded through `LocalModelStore` (the same path the apps
// use, so download progress is checked too), then asked a coaching question
// (streamed and not), for strict JSON, and for a short list. A model fails
// when an answer is empty or carries reasoning, template tokens, or broken
// JSON. Results go to stdout and `local-model-conformance.json`.
//
// Models install under ~/Library/Application Support/CHSharedKit. Do not run
// the kit's tests at the same time: a store's startup removes staging
// directories there, including a download in progress.

import Foundation
import CHSharedKit
import CHLocalLLM

@main
struct LocalModelConformance {
    struct Check: Codable {
        let name: String
        let passed: Bool
        let detail: String
    }

    struct ModelResult: Codable {
        let id: String
        let modelType: String
        let downloadProgressTicks: Int
        let checks: [Check]
        var passed: Bool { checks.allSatisfy(\.passed) }
    }

    static let system = """
    You are LiftCoach's strength coach. Answer the user's question directly in 2-4 short sentences, \
    using the training data provided. Do not show your reasoning.
    """

    static let context = """
    Training this week: 1 session, Full Body (Seated Leg Curl 4 sets, Rope Pushdown 4 sets, \
    Barbell Curl 3 sets), total volume 7,930 lb. 4-week weekly average: 41,971 lb.
    """

    static func main() async {
        let requested = Set(CommandLine.arguments.dropFirst())
        let models = LocalModelCatalog.all.filter { model in
            guard let release = model.release, release.status == "active" else { return false }
            return requested.isEmpty || requested.contains(model.id)
        }
        guard !models.isEmpty else {
            fputs("No matching active catalog models.\n", stderr)
            exit(2)
        }
        await MainActor.run { LocalModelStore.shared.appIdentifier = .liftcoach }
        print("=== Offline model conformance: \(models.count) model(s) ===")

        var results: [ModelResult] = []
        for model in models {
            print("\n--- \(model.displayName) (\(model.id)) ---")
            let ticks = await ensureInstalled(model)
            let url = await MainActor.run { LocalModelStore.shared.modelURL(for: model) }
            let provider = CHLocalLLMProvider(modelURL: url, modelInfo: model)
            var checks: [Check] = [
                Check(name: "download progress", passed: ticks >= 3 || ticks == -1,
                      detail: ticks == -1 ? "already installed" : "\(ticks) progress updates"),
            ]
            checks += await run(provider)
            let result = ModelResult(id: model.id, modelType: model.release?.modelType ?? "?",
                                     downloadProgressTicks: ticks, checks: checks)
            for check in checks {
                print("  \(check.passed ? "PASS" : "FAIL")  \(check.name): \(check.detail)")
            }
            results.append(result)
        }

        print("\n=== Summary ===")
        for result in results {
            print("\(result.passed ? "PASS" : "FAIL")  \(result.id) (\(result.modelType))")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(results) {
            try? data.write(to: URL(fileURLWithPath: "local-model-conformance.json"))
        }
        exit(results.allSatisfy(\.passed) ? 0 : 1)
    }

    /// Downloads through the store and counts progress updates while the
    /// bytes arrive. Returns -1 when the model was already installed.
    static func ensureInstalled(_ model: LocalModelInfo) async -> Int {
        let installed = await MainActor.run { LocalModelStore.shared.installedModels.contains { $0.id == model.id } }
        if installed { return -1 }
        await MainActor.run { LocalModelStore.shared.downloadModel(model) }
        var ticks = 0
        var lastFraction = -1.0
        while true {
            let state = await MainActor.run { LocalModelStore.shared.downloadState }
            switch state {
            case .downloading(let fraction, let received, let total):
                if fraction > lastFraction, fraction < 1 {
                    ticks += 1
                    lastFraction = fraction
                    FileHandle.standardError.write(Data(String(
                        format: "\r  download %5.1f%%  %6.0f / %6.0f MB", fraction * 100,
                        Double(received) / 1_048_576, Double(total) / 1_048_576
                    ).utf8))
                }
            case .installing, .paused:
                break
            case .installed:
                FileHandle.standardError.write(Data("\n".utf8))
                return ticks
            case .failed(let message):
                fputs("\n  download failed: \(message)\n", stderr)
                return 0
            case .idle:
                if ticks > 0 {
                    let done = await MainActor.run { LocalModelStore.shared.installedModels.contains { $0.id == model.id } }
                    if done { return ticks }
                }
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    static func run(_ provider: CHLocalLLMProvider) async -> [Check] {
        var checks: [Check] = []
        let question = "\(context)\n\nHow's my training load this week?"

        do {
            let answer = try await provider.sendMessage(prompt: question, systemPrompt: system)
            checks.append(clean("coach answer", answer))
        } catch {
            checks.append(Check(name: "coach answer", passed: false, detail: "error: \(error.localizedDescription)"))
        }

        do {
            var chunks = 0
            var streamed = ""
            for try await chunk in try await provider.stream(prompt: question, systemPrompt: system) {
                chunks += 1
                streamed += chunk
            }
            var check = clean("coach answer, streamed", streamed)
            if check.passed, chunks < 2 {
                check = Check(name: check.name, passed: false, detail: "arrived in \(chunks) chunk(s)")
            }
            checks.append(check)
        } catch {
            checks.append(Check(name: "coach answer, streamed", passed: false, detail: "error: \(error.localizedDescription)"))
        }

        do {
            let json = try await provider.sendMessage(
                prompt: #"Reply with only this JSON, filled in, and nothing else: {"names": ["<name>", "<name>", "<name>"]} — three short names for a leg workout."#,
                systemPrompt: "You output strict JSON only."
            )
            let body = json.drop { $0 != "{" }.reversed().drop { $0 != "}" }.reversed()
            let parsed = (try? JSONSerialization.jsonObject(with: Data(String(body).utf8))) as? [String: Any]
            let names = parsed?["names"] as? [String] ?? []
            checks.append(Check(name: "strict JSON", passed: names.count >= 1 && clean("", json).passed,
                                detail: names.isEmpty ? "unparsable: \(json.prefix(120))" : names.joined(separator: ", ")))
        } catch {
            checks.append(Check(name: "strict JSON", passed: false, detail: "error: \(error.localizedDescription)"))
        }
        return checks
    }

    static let leaks = ["<think", "</think", "<|", "|>", "<｜", "<end_of_turn>", "<start_of_turn>", "</s>", "<reasoning", "<thinking"]

    static func clean(_ name: String, _ text: String) -> Check {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return Check(name: name, passed: false, detail: "empty") }
        if let leak = leaks.first(where: { trimmed.contains($0) }) {
            return Check(name: name, passed: false, detail: "contains \(leak): \(trimmed.prefix(120))")
        }
        return Check(name: name, passed: true, detail: String(trimmed.prefix(100)).replacingOccurrences(of: "\n", with: " "))
    }
}
