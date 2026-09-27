// Offline model conformance: every active catalog model must give a chat UI
// a plain answer. Run on an Apple Silicon Mac:
//
//   swift run local-model-conformance              # every active model
//   swift run local-model-conformance qwen3-1.7b-q4 llama3.2-1b-q4km
//   swift run local-model-conformance --fresh qwen3-1.7b-q4   # delete, download again
//   swift run local-model-conformance --languages              # also: reply-language matrix
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
import NaturalLanguage
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
        let arguments = CommandLine.arguments.dropFirst()
        let fresh = arguments.contains("--fresh")
        let checkLanguages = arguments.contains("--languages")
        let requested = Set(arguments.filter { !$0.hasPrefix("--") })
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
        var languageMatrix: [String: [String: Bool]] = [:]
        for model in models {
            print("\n--- \(model.displayName) (\(model.id)) ---")
            if fresh {
                await MainActor.run { LocalModelStore.shared.deleteModel(model) }
            }
            let started = Date()
            let ticks = await ensureInstalled(model)
            let seconds = Date().timeIntervalSince(started)
            let hops = await MainActor.run { LocalModelStore.shared.progressHopCount }
            let url = await MainActor.run { LocalModelStore.shared.modelURL(for: model) }
            let provider = CHLocalLLMProvider(modelURL: url, modelInfo: model)
            var checks: [Check] = [
                Check(name: "download progress", passed: ticks >= 3 || ticks == -1,
                      detail: ticks == -1 ? "already installed" : "\(ticks) progress updates"),
            ]
            if ticks != -1 {
                // 2.19.9 bounds main-actor work to ~10 progress hops a second;
                // 2.19.8 sent one per URLSession callback and froze iPhones.
                let rate = Double(hops) / max(seconds, 1)
                checks.append(Check(name: "progress hops bounded", passed: rate <= 15,
                                    detail: String(format: "%d hops in %.0f s (%.1f/s)", hops, seconds, rate)))
            }
            checks += await run(provider)
            if checkLanguages {
                let matrix = await languages(provider)
                languageMatrix[model.id] = matrix
                let followed = matrix.filter { $0.value }.keys.sorted()
                print("  languages followed \(followed.count)/\(matrix.count): \(followed.joined(separator: " "))")
            }
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
        if checkLanguages {
            // Informational: which models answer in which language. Apps can
            // use it to point users at a model that speaks their language.
            print("\n=== Reply language (question asked in the language, with the reply rule) ===")
            let codes = languageSamples.map(\.code)
            print("model".padding(toLength: 24, withPad: " ", startingAt: 0) + codes.map { $0.padding(toLength: 8, withPad: " ", startingAt: 0) }.joined())
            for id in languageMatrix.keys.sorted() {
                let row = codes.map { (languageMatrix[id]?[$0] == true ? "yes" : "-").padding(toLength: 8, withPad: " ", startingAt: 0) }
                print(id.padding(toLength: 24, withPad: " ", startingAt: 0) + row.joined())
            }
            if let data = try? encoder.encode(languageMatrix) {
                try? data.write(to: URL(fileURLWithPath: "local-model-languages.json"))
            }
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

    // MARK: Reply language

    /// A coaching question in each language, with the language it expects
    /// back. The rule mirrors what apps add to their system prompts.
    static let languageSamples: [(code: String, name: String, question: String, expected: [NLLanguage])] = [
        ("zh-Hans", "Simplified Chinese", "我这周的训练负荷怎么样？", [.simplifiedChinese]),
        ("zh-Hant", "Traditional Chinese", "我這週的訓練負荷如何？", [.traditionalChinese]),
        ("ja", "Japanese", "今週のトレーニング負荷はどう？", [.japanese]),
        ("ko", "Korean", "이번 주 운동 부하는 어때?", [.korean]),
        ("de", "German", "Wie ist meine Trainingsbelastung diese Woche?", [.german]),
        ("fr", "French", "Quelle est ma charge d’entraînement cette semaine ?", [.french]),
        ("es", "Spanish", "¿Cómo va mi carga de entrenamiento esta semana?", [.spanish]),
        ("pt-BR", "Brazilian Portuguese", "Como está minha carga de treino nesta semana?", [.portuguese]),
        ("ru", "Russian", "Какая у меня тренировочная нагрузка на этой неделе?", [.russian]),
        ("ar", "Arabic", "ما مستوى حمل تدريبي هذا الأسبوع؟", [.arabic]),
    ]

    static func languages(_ provider: CHLocalLLMProvider) async -> [String: Bool] {
        var matrix: [String: Bool] = [:]
        for sample in languageSamples {
            let rule = "Language: write every reply in \(sample.name). If the user writes in another language, reply in that language instead."
            do {
                let answer = try await provider.sendMessage(
                    prompt: "\(context)\n\n\(sample.question)",
                    systemPrompt: system + "\n\n" + rule
                )
                let recognizer = NLLanguageRecognizer()
                recognizer.processString(answer)
                let detected = recognizer.dominantLanguage
                // Traditional vs Simplified Chinese can be close; either
                // counts as Chinese, the exact script is reported separately.
                var ok = detected.map { sample.expected.contains($0) } ?? false
                if !ok, sample.code.hasPrefix("zh"), detected == .simplifiedChinese || detected == .traditionalChinese {
                    ok = true
                }
                matrix[sample.code] = ok
            } catch {
                matrix[sample.code] = false
            }
        }
        return matrix
    }
}
