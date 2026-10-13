#!/usr/bin/env swift

// validate-settings-rows.swift
//
// Greps app source for HStack-shaped Settings rows that bypass the
// `CHSettingsRow` primitive shipped in CHSharedKit 2.9.1+. Wire into
// each app's Xcode build phase to fail the build on regressions.
//
// Usage:
//
//     "${SRCROOT}/Pods/CHSharedKit/Scripts/validate-settings-rows.swift" \
//         "${SRCROOT}" \
//         [--fail | --warn]
//
// Default mode is `--warn` (prints findings, exits 0). Pass `--fail`
// to make the build phase fail when any flagged pattern is found.
//
// What gets flagged
// -----------------
//
// Heuristic style checks; false positives are possible. Three patterns:
//
//   1. `HStack` block where the body contains both `Image(systemName:)`
//      and `Text(...)` AND the file path lives under `*/Settings/*`
//      OR the file name contains `Settings`. These are settings-row-
//      shaped HStacks that aren't the kit primitive.
//
//   2. `Label("...", systemImage: "...")` inside a `Section { ... }`
//      block (Settings sections). Apple's `Label` is fine in lots of
//      contexts but in a Settings section it produces a different
//      visual than `CHSettingsRow` (no badge, smaller icon). Either
//      switch to `CHSettingsRow` or extract.
//
//   3. `NavigationLink { ... } label: { Text(...) }` or
//      `Button { ... } label: { Text(...) }` directly in a Settings
//      section — bare Text labels with no icon. These are flagged
//      because Settings rows in the kit always have an icon badge.
//
// Files containing the literal string `// CHSETTINGS_ROW_LINT_OFF`
// are skipped — escape hatch for genuine non-row uses inside Settings
// directories (e.g. a custom card layout that's not meant to look
// like a row).
//
// Exit codes
// ----------
//   0 — nothing flagged (or `--warn` mode regardless)
//   1 — `--fail` mode + at least one flagged pattern
//  64 — usage error

import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("""
    usage: \(args[0]) <source-root> [--fail|--warn]

    Audits Settings views for cells that bypass CHSettingsRow.

    """, stderr)
    exit(64)
}

let sourceRoot = args[1]
let failMode = args.contains("--fail")

let fm = FileManager.default
guard let enumerator = fm.enumerator(atPath: sourceRoot) else {
    fputs("[source] could not enumerate \(sourceRoot)\n", stderr)
    exit(1)
}

struct Finding {
    let path: String
    let line: Int
    let snippet: String
    let rule: String
}

var findings: [Finding] = []

while let relative = enumerator.nextObject() as? String {
    guard relative.hasSuffix(".swift") else { continue }
    if relative.contains(".build/") || relative.contains("DerivedData/") { continue }
    if relative.contains("/.git/") || relative.hasPrefix(".git/") { continue }
    if relative.contains("/Pods/") { continue }
    // The kit's own source is allowed to use HStack however it wants.
    if relative.contains("CHSharedKit/Sources") { continue }

    let absolute = (sourceRoot as NSString).appendingPathComponent(relative)
    guard let data = fm.contents(atPath: absolute),
          let source = String(data: data, encoding: .utf8)
    else { continue }
    if source.contains("// CHSETTINGS_ROW_LINT_OFF") { continue }

    let isSettingsContext = relative.lowercased().contains("settings")
        || relative.lowercased().contains("preferences")
    // The "isSettingsContext" filter keeps this from flagging every
    // HStack in the codebase. Apps that put settings code outside of
    // a Settings/ directory: rename the directory, or add `// CHSETTINGS_ROW_LINT_ON`
    // file-marker support in a future kit release.
    guard isSettingsContext else { continue }

    let lines = source.components(separatedBy: .newlines)

    // Pattern 1: HStack containing Image(systemName:) AND Text(...)
    var inHStackDepth = 0
    var hstackStartLine = 0
    var hstackHasImage = false
    var hstackHasText = false
    for (idx, line) in lines.enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("HStack") && trimmed.contains("{") {
            if inHStackDepth == 0 {
                hstackStartLine = idx + 1
                hstackHasImage = false
                hstackHasText = false
            }
            inHStackDepth += 1
        }
        if inHStackDepth > 0 {
            if line.contains("Image(systemName:") { hstackHasImage = true }
            if line.range(of: #"Text\(""#, options: .regularExpression) != nil { hstackHasText = true }
            // Closing brace at column-0-ish — heuristic for end of
            // the HStack block. False positive on multi-line trailing
            // closures; acceptable for a lint pass.
            if trimmed == "}" {
                inHStackDepth -= 1
                if inHStackDepth == 0 && hstackHasImage && hstackHasText {
                    findings.append(Finding(
                        path: relative,
                        line: hstackStartLine,
                        snippet: lines[hstackStartLine - 1].trimmingCharacters(in: .whitespaces),
                        rule: "HStack with Image(systemName:) + Text — use CHSettingsRow"
                    ))
                }
            }
        }
    }

    // Pattern 2: Label inside a Section
    var inSectionDepth = 0
    for (idx, line) in lines.enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("Section") && trimmed.contains("{") {
            inSectionDepth += 1
        }
        if inSectionDepth > 0,
           line.range(of: #"Label\("[^"]+"\s*,\s*systemImage:"#, options: .regularExpression) != nil {
            findings.append(Finding(
                path: relative,
                line: idx + 1,
                snippet: trimmed,
                rule: "Label(_:systemImage:) inside Section — use CHSettingsRow"
            ))
        }
        if trimmed == "}" && inSectionDepth > 0 {
            inSectionDepth -= 1
        }
    }

    // Pattern 3: NavigationLink/Button label: { Text(...) } directly
    // in a Settings section. Heuristic regex — any line with the
    // label-block-Text shape. Loose by design.
    for (idx, line) in lines.enumerated() {
        if line.range(of: #"label:\s*\{\s*Text\(""#, options: .regularExpression) != nil {
            findings.append(Finding(
                path: relative,
                line: idx + 1,
                snippet: line.trimmingCharacters(in: .whitespaces),
                rule: "Bare Text label on NavigationLink/Button — use CHSettingsRow"
            ))
        }
    }
}

if findings.isEmpty {
    print("✅ Settings-row audit passed (no HStack-shaped Settings cells found outside CHSettingsRow)")
    exit(0)
}

print("⚠️  Settings-row audit flagged \(findings.count) candidate site\(findings.count == 1 ? "" : "s"):\n")
for f in findings.sorted(by: { ($0.path, $0.line) < ($1.path, $1.line) }) {
    print("  \(f.path):\(f.line)")
    print("    \(f.rule)")
    print("    > \(f.snippet)")
    print()
}
print("""
Fix:
  • Replace the flagged HStack/Label/Text with CHSettingsRow:
        CHSettingsRow(icon: "<sf-symbol>", iconColor: .accent, title: "<title>")
    Wrap in NavigationLink / Toggle / Picker / Button as appropriate.
  • If the cell is genuinely not a Settings row (custom card, hero
    block, etc.), add the comment `// CHSETTINGS_ROW_LINT_OFF`
    anywhere in the file to skip it.
""")

exit(failMode ? 1 : 0)
