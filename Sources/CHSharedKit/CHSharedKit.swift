// The Swift Programming Language
// https://docs.swift.org/swift-book

// CHSharedKit - Shared components for Chen's iOS/macOS apps
//
// AI Provider System:
//   - CHAIProvider: Protocol for AI providers
//   - CHAIManager: Central manager for AI requests
//   - CHOpenAIProvider: OpenAI GPT provider
//   - CHClaudeProvider: Anthropic Claude provider
//   - CHCustomEndpointProvider: OpenAI-compatible custom endpoints
//   - CHAppleIntelligenceProvider: On-device Apple Intelligence (iOS 26+)
//   - CHAISettingsView: SwiftUI settings UI for provider configuration
//   - CHAIUsageTracker: Token usage and cost tracking
//   - CHAIKeychain: Secure API key storage
//   - CHAIError: Error types for AI operations
//
// Developer Tools:
//   - CHLogger: Unified logging system
//   - CHLogViewerView: SwiftUI log viewer
//   - CHDeveloperMenuModifier: Developer menu view modifier
//
// Backup:
//   - CHBackupKit: Backup and restore utilities
//
// Theme System:
//   - Theme / ThemeColor: Codable theme + per-mode color tokens
//   - ThemePalette: 8 pre-designed themes (Default, Midnight, Ocean, Sunset,
//     Forest, Paper, Aurora, Monochrome)
//   - ThemeManager: @MainActor controller, syncs via NSUbiquitousKeyValueStore,
//     swaps alternate app icons via UIApplication.setAlternateIconName
//   - ThemePickerView: drop-in SwiftUI grid picker
//   - View.themed(_:) modifier + @Environment(\.theme) access
