# Offline model catalog (2.15.0)

CHLocalLLM reads a versioned catalog from:

`https://raw.githubusercontent.com/hechen/ai-model-catalog/main/offline-model-catalog.json`

The public `hechen/ai-model-catalog` repository owns the live JSON and its validator. The SDK bundles a validated copy for first launch and offline startup. Valid remote revisions are cached atomically. A malformed, older, or same-revision-but-different response leaves the current catalog intact. Refreshing listings never downloads model weights, changes an installed descriptor, or switches providers.

## Host integration

```swift
import CHLocalLLM

// Existing provider filtering, purchase and privacy boundaries still apply.
LocalModelStore.shared.appIdentifier = .liftcoach

// In a launch task. The shared model picker also refreshes when opened.
await CHOfflineModelCatalog.shared.refreshIfNeeded()

// LocalModelStore initialization restores the active installed descriptor
// and registers it only when compatible with the text provider. To inspect it:
if let id = LocalModelStore.shared.activeModelID {
    let installed = LocalModelStore.shared.installedModel(forID: id)
    // installed?.release identifies the actual downloaded revision.
}
```

`LocalModelCatalog.all` retains its existing API shape but now reads the catalog snapshot. Named static model constants remain for source compatibility and legacy-install migration; new downloads should use the dynamic catalog. Custom MLX repositories remain available as unverified advanced entries.

## Release identity and installation

Catalog revision is a monotonic integer. Each model separately pins a full Hugging Face commit and an exact file manifest (relative path, byte count, SHA-256). New downloads use those immutable file URLs, verify the full manifest, check tokenizer/weight shards and architecture, then load the staged model and run a bounded short synthetic response. Only then can the installation registry switch to the new directory. A failed or cancelled update keeps the old installation. Catalog refresh is not model update: the user explicitly selects Update.

The installation registry stores its own model descriptor and directory, independently from the remote listing. Retired or removed installed models stay visible and loadable; they are not silently deleted or replaced. Legacy snapshots are migrated without inventing a verified revision. Staging and installed revisions never share mutable files. Removing the active model unregisters its loaded provider and returns provider selection to Apple Intelligence rather than a cloud service.

Runtime validation has finite token/KV limits and a cooperative deadline. MLX cold loading may take time to respond to cancellation; the deadline is not a hard guarantee of memory reclamation or return time. The validation coordinator retains its slot until cancelled native work drains, so a retry cannot overlap another installation check. Cancellation always prevents committing the staged release. Interrupted staging directories are removed at the next launch.

## Compatibility and recommendations

The client enforces its compiled runtime version and text-model architecture registry. An unknown runtime/model type can appear in metadata but cannot be downloaded through the text loader. New weights for a supported architecture can be catalog-only changes; new runtime implementations require an SDK/app update.

The picker describes RAM as an estimate. Repository availability, file integrity, runtime smoke testing, and fitness for an app's tasks are distinct. A recommendation badge requires `verification: passed` and an evidence record for that app; initial listings are unverified candidates. Model quality labels and language lists are publisher/catalog metadata, not measured guarantees.

The initial catalog retires Qwen2.5 3B from new downloads because its source uses the Qwen Research license, preserves existing installations, and removes the unavailable SmolLM2 URL and misrouted Qwen2-VL offer. Llama/Gemma/other special licenses show their terms before a new download. New licenses can use `Other` with `licenseName`, `licenseURL`, and acknowledgment; a new SDK enum case is not required.

## Validation and publication

Run the catalog repository's Python validator/tests and the SDK's `CHOfflineModelCatalogTests` and `OfflineModelInstallationTests`. Tests cover invalid paths/manifests, cache fallback, stale revisions, new remote IDs, download integrity, cancellation, failed runtime validation, atomic replacement and legacy snapshots. They use synthetic fixture files, not gigabytes of model weights.

Before marking an app recommendation passed, run real model evaluations on physical target devices and retain the model revision, runtime/app version, OS/device, language, task results, latency and peak memory. A successful eight-token installation check is not an evaluation of workout plans or health-related answer quality.
