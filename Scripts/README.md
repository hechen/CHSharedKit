# CHSharedKit Scripts

Build-time and developer-time tools that ship with the kit. Apps wire
these into their own Xcode build phases or run them locally; nothing
here is invoked from kit-internal code.

## `validate-entitlements.swift`

Build-phase guard that fails the build on:

1. Missing iCloud / Keychain entitlements in the app's `.entitlements`
   plist (CloudKit, CloudDocuments, non-empty `keychain-access-groups`,
   non-empty `com.apple.developer.icloud-container-identifiers`).
2. Direct `SecItemAdd(` calls in app source that don't pass
   `kSecAttrSynchronizable` — i.e. callsites that bypass
   `CHSyncedKeychain` and would silently break cross-device sync.

Wire it into Xcode under **Build Phases → "+" → New Run Script Phase**:

```
"${BUILT_PRODUCTS_DIR}/../../SourcePackages/checkouts/CHSharedKit/Scripts/validate-entitlements.swift" \
  "${PROJECT_DIR}/${INFOPLIST_FILE%/*}/<YourApp>.entitlements" \
  "${SRCROOT}"
```

(SwiftPM checkout path varies — adjust per your project layout. The
script only needs absolute paths to the entitlements file and the
source root.)

Exits 0 on success, 1 with a list of offenders on failure.

## `validate-settings-rows.swift`

Build-phase guard that flags Settings views in app source that bypass
`CHSettingsRow`. Three rules:

1. `HStack { … }` blocks under `*/Settings/*` containing both
   `Image(systemName:)` and `Text(…)` — settings-row-shaped HStacks
   that should be the kit primitive.
2. `Label("…", systemImage: …)` inside a `Section { … }` block —
   uses Apple's `Label` (no badge) instead of `CHSettingsRow`'s
   squircle-badge convention.
3. `NavigationLink` / `Button` with bare `Text` labels (no icon) in
   a Settings section — every Settings row in the kit has an icon.

Wire into Xcode under **Build Phases → "+" → New Run Script Phase**:

```
"${BUILT_PRODUCTS_DIR}/../../SourcePackages/checkouts/CHSharedKit/Scripts/validate-settings-rows.swift" \
  "${SRCROOT}" \
  --fail
```

Default mode is `--warn` (prints findings, exits 0). Pass `--fail`
once the app's existing flagged sites have been fixed; from then on
new regressions break the build.

Files containing `// CHSETTINGS_ROW_LINT_OFF` are skipped — escape
hatch for genuine non-row uses inside Settings directories (custom
cards, hero blocks, etc).

## `check-consumer-versions.sh`

Local script that reports CHSharedKit version drift across all known
consumer apps. Run from the kit's repo root:

```
./Scripts/check-consumer-versions.sh
```

Output:

```
Latest CHSharedKit tag: 2.9.0

CONSUMER               VERSION    DRIFT
---------------------  ---------- -----------------
EatWisely              2.8.1      BEHIND 1 minor
GymLog                 2.8.1      BEHIND 1 minor
Distill                1.4.4      BEHIND 1 major
…
```

Used to drive the **lockstep bump** policy: any minor tag of
CHSharedKit should fan out to all active consumers within ~1 minor.
The bump PR description should include the output of this script.

Requires `gh` (authenticated) and `jq`.

## What's NOT here, and why

### Two-simulator iCloud sync CI harness

Aspirational. Apple ID sign-in is interactive (2FA codes, no headless
flow), shared test accounts get rate-limited / locked, and the iCloud
KVS daemon's sync latency isn't deterministic enough to assert against
in a 30s window. The realistic substitute lives in
`Tests/CHSharedKitTests/CHSyncTests.swift` — those tests use a
`FakeUbiquitousKVS` shared between two `CHSyncedSettingsStore`
instances, exercising the propagation logic from a single process.
Real-device verification is a manual protocol:

1. Sign two physical devices into the same iCloud account.
2. Install the app's TestFlight build on both.
3. Make a synced change on device A; wait 30s; verify on device B.

When a way to script this safely exists (e.g. a future Xcode Cloud
hook for paired-device testing), revisit.

### Cross-repo build matrix CI

Aspirational. Spawning per-app builds from the kit's CI requires
fine-grained PATs into each consumer's private repo and would need
careful caching to stay under GitHub Actions minutes. The realistic
substitute is `check-consumer-versions.sh` — surfacing drift weekly is
cheaper than running 8 full builds on every kit PR. When we hit a
drift-driven regression that this approach misses, revisit.
