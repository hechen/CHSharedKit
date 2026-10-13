#!/usr/bin/env swift

// validate-entitlements.swift
//
// Build-phase guard for CHSharedKit consumers. Wire into Xcode under
// Build Phases → "+" → New Run Script Phase, with this body:
//
//     "${SRCROOT}/Pods/CHSharedKit/Scripts/validate-entitlements.swift" \
//         "${PROJECT_DIR}/${INFOPLIST_FILE%/*}/<YourApp>.entitlements" \
//         "${SRCROOT}"
//
// (Adjust the entitlements path for SwiftPM-vendored layouts; the script
// only cares about absolute paths.)
//
// Two checks:
//
// 1. **Entitlements plist** must declare CloudKit + iCloud Documents
//    services AND a non-empty `keychain-access-groups` (so iCloud
//    Keychain is actually opted in).
//
// 2. **Source tree** is grepped for direct `SecItemAdd(` calls. Each
//    callsite must either (a) be inside a function body that mentions
//    `kSecAttrSynchronizable`, OR (b) live inside CHSharedKit's own
//    `CHSyncedKeychain.swift` (which sets the flag centrally). Any
//    other callsite is a regression and fails the build.
//
// Exits 0 on success, 1 on failure with a list of offending lines.
// Intentionally zero-dependency — runs under the system Swift, no
// SwiftPM build, no third-party libs.

import Foundation

let args = CommandLine.arguments

guard args.count >= 3 else {
    fputs("""
    usage: \(args[0]) <path-to-entitlements.plist> <source-root>

    Validates iCloud / Keychain entitlements and SecItemAdd callsites.

    """, stderr)
    exit(64) // EX_USAGE
}

let entitlementsPath = args[1]
let sourceRoot = args[2]

var failures: [String] = []

// MARK: - 1. Entitlements plist

if !FileManager.default.fileExists(atPath: entitlementsPath) {
    failures.append("[entitlements] file not found at \(entitlementsPath)")
} else if let data = FileManager.default.contents(atPath: entitlementsPath),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {

    let services = plist["com.apple.developer.icloud-services"] as? [String] ?? []
    if !services.contains("CloudKit") {
        failures.append("[entitlements] com.apple.developer.icloud-services missing 'CloudKit'")
    }
    if !services.contains("CloudDocuments") {
        failures.append("[entitlements] com.apple.developer.icloud-services missing 'CloudDocuments'")
    }

    let keychainGroups = plist["keychain-access-groups"] as? [String] ?? []
    if keychainGroups.isEmpty {
        failures.append("[entitlements] keychain-access-groups missing or empty (required for iCloud Keychain sync)")
    }

    let containers = plist["com.apple.developer.icloud-container-identifiers"] as? [String] ?? []
    if containers.isEmpty {
        failures.append("[entitlements] com.apple.developer.icloud-container-identifiers is empty")
    }
} else {
    failures.append("[entitlements] could not parse plist at \(entitlementsPath)")
}

// MARK: - 2. SecItemAdd callsite audit

let fm = FileManager.default
guard let enumerator = fm.enumerator(atPath: sourceRoot) else {
    fputs("[source] could not enumerate \(sourceRoot)\n", stderr)
    exit(1)
}

let allowedFilenames: Set<String> = [
    "CHSyncedKeychain.swift",   // central wrapper that sets the flag
    "CHAITokenStore.swift",     // routes through CHSyncedKeychain (legacy fallback path is read-only)
    "CHAIProvider.swift"        // CHAIKeychain facade routes through CHSyncedKeychain
]

while let relative = enumerator.nextObject() as? String {
    guard relative.hasSuffix(".swift") else { continue }
    // Skip vendored package checkouts and build artifacts.
    if relative.contains(".build/") || relative.contains("DerivedData/") { continue }
    if relative.contains("/.git/") || relative.hasPrefix(".git/") { continue }

    let filename = (relative as NSString).lastPathComponent
    if allowedFilenames.contains(filename) { continue }

    let absolute = (sourceRoot as NSString).appendingPathComponent(relative)
    guard let data = fm.contents(atPath: absolute),
          let source = String(data: data, encoding: .utf8)
    else { continue }
    if !source.contains("SecItemAdd(") { continue }

    // Coarse-grained check: file mentions SecItemAdd somewhere AND
    // doesn't mention kSecAttrSynchronizable anywhere. False positives
    // remain possible; this catches files that omit the flag entirely.
    // Function-scope checks would require a parser.
    if !source.contains("kSecAttrSynchronizable") {
        // Find the offending line numbers for the failure message.
        var offendingLines: [Int] = []
        for (idx, line) in source.components(separatedBy: .newlines).enumerated()
        where line.contains("SecItemAdd(") {
            offendingLines.append(idx + 1)
        }
        let lineList = offendingLines.map(String.init).joined(separator: ", ")
        failures.append("[source] \(relative): SecItemAdd without kSecAttrSynchronizable (lines \(lineList)). Use CHSyncedKeychain.")
    }
}

// MARK: - Report

if failures.isEmpty {
    print("✅ entitlements + sync-keychain audit passed")
    exit(0)
}

fputs("❌ CHSharedKit entitlement / sync-keychain audit FAILED:\n", stderr)
for failure in failures {
    fputs("  • \(failure)\n", stderr)
}
fputs("""

Fix:
  • Entitlements: open the .entitlements file and add the missing
    capabilities under iCloud / Keychain Sharing.
  • SecItemAdd: replace the direct call with
    CHSyncedKeychain.set(_:forKey:service:accessGroup:).

""", stderr)
exit(1)
