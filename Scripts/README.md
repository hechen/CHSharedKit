# Optional host-project checks

These standalone Swift scripts can run locally or in a host app's Xcode build phase. The package does not invoke them automatically. They encode optional integration conventions, not prerequisites for using every product.

## Entitlements and Keychain conventions

```sh
swift /path/to/CHSharedKit/Scripts/validate-entitlements.swift \
  /path/to/MyApp.entitlements /path/to/MyApp/Sources
```

`validate-entitlements.swift` checks for CloudKit and CloudDocuments services, nonempty iCloud container identifiers, and nonempty Keychain access groups. It also flags Swift files containing `SecItemAdd(` without `kSecAttrSynchronizable`, except known wrapper files.

Use this only for apps that deliberately adopt those iCloud and Keychain conventions. It is a coarse source/plist check: it does not validate provisioning, sandbox behavior, each individual Keychain call, or successful synchronization. Exit status is 0 on success, 1 on findings, and 64 for invalid arguments.

## Settings row conventions

```sh
swift /path/to/CHSharedKit/Scripts/validate-settings-rows.swift \
  /path/to/MyApp/Sources --warn
```

`validate-settings-rows.swift` flags heuristic row patterns in Settings code that differ from `CHSettingsRow`: icon/text HStacks, system Labels, and bare-text button or navigation labels. These are style findings, not correctness errors, and may include false positives.

The default `--warn` mode reports findings with exit status 0. `--fail` returns 1 when findings exist. Files containing `// CHSETTINGS_ROW_LINT_OFF` are skipped. Use that marker for intentional custom layouts after reviewing the result.

For Xcode build phases, use the actual package checkout path and your app's source path; checkout locations depend on your build configuration. Neither script substitutes for native UI or device testing.
