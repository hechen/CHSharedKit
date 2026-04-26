// Smoke test: actually load Qwen2.5-3B-Instruct-4bit via CHLocalLLMProvider
// and stream a real response. Run with:
//
//   swift run mlx-smoke "Write a haiku about Swift programming."
//
// First run downloads ~1.7 GB from huggingface.co (cached afterwards in
// `~/Library/Application Support/CHSharedKit/models/`).
//
// Exits with code 0 on at least one streamed token, 1 otherwise.

import Foundation
import CHLocalLLM
import Hub

@main
struct MLXSmoke {

    static func main() async {
        let prompt = CommandLine.arguments.dropFirst().first
            ?? "Write a one-sentence greeting."
        let info = LocalModelCatalog.qwen2_5_3B
        let repoID = CHLocalMLXRepoID.from(info.downloadURL)!

        print("=== CHSharedKit MLX smoke test ===")
        print("Model:    \(info.displayName) (\(repoID))")
        print("Prompt:   \(prompt)")
        print("Storage:  \(CHLocalMLXStorage.baseDirectory.path)")
        print()

        // Step 1: ensure the model is downloaded.
        let dir = CHLocalMLXStorage.localDirectory(forRepoID: repoID)
        let configURL = dir.appendingPathComponent("config.json")
        if !FileManager.default.fileExists(atPath: configURL.path) {
            print("Downloading model snapshot — this takes a few minutes on first run...")
            do {
                let hub = CHLocalMLXStorage.hubApi()
                let progressHandler: @Sendable (Progress) -> Void = { progress in
                    let pct = Int(progress.fractionCompleted * 100)
                    if pct % 5 == 0 {
                        FileHandle.standardError.write(Data("\rDownload: \(pct)%".utf8))
                    }
                }
                _ = try await hub.snapshot(
                    from: Hub.Repo(id: repoID),
                    matching: ["*.safetensors", "*.json"],
                    progressHandler: progressHandler
                )
                FileHandle.standardError.write(Data("\rDownload: 100%\n".utf8))
            } catch {
                fputs("Download failed: \(error)\n", stderr)
                exit(1)
            }
        } else {
            print("Snapshot already present at \(dir.path) — skipping download.")
        }
        print()

        // Step 2: load the model and stream a response.
        print("Loading model into MLX (cold start)...")
        let coldStart = Date()
        let provider = await MainActor.run {
            CHLocalLLMProvider(
                modelURL: dir,
                modelInfo: info
            )
        }

        do {
            let stream = try await provider.stream(
                prompt: prompt,
                systemPrompt: "You are a concise assistant. Reply in one sentence."
            )
            print("First token after \(String(format: "%.2f", Date().timeIntervalSince(coldStart))) s of cold start (estimate was \(String(format: "%.2f", provider.coldStartLatencyEstimate)) s)")
            print()
            print("--- response ---")
            var tokens = 0
            for try await chunk in stream {
                FileHandle.standardOutput.write(Data(chunk.utf8))
                tokens += 1
            }
            print()
            print("--- done (\(tokens) chunks) ---")
            if tokens == 0 {
                fputs("No tokens streamed — smoke test failed.\n", stderr)
                exit(1)
            }
        } catch {
            fputs("Generation failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
