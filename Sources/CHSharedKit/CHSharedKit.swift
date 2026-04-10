// The Swift Programming Language
// https://docs.swift.org/swift-book

// CHSharedKit - Shared components for Chen's iOS/macOS apps
//
// AI Provider System:
//   - ClawdAIProvider: Protocol for AI providers
//   - ClawdAIManager: Central manager for AI requests
//   - ClawdOpenAIProvider: OpenAI GPT provider
//   - ClawdClaudeProvider: Anthropic Claude provider
//   - ClawdCustomEndpointProvider: OpenAI-compatible custom endpoints
//   - ClawdAppleIntelligenceProvider: On-device Apple Intelligence (iOS 26+)
//   - ClawdAISettingsView: SwiftUI settings UI for provider configuration
//   - ClawdAIUsageTracker: Token usage and cost tracking
//   - ClawdAIKeychain: Secure API key storage
//   - ClawdAIError: Error types for AI operations
//
// Developer Tools:
//   - ClawdLogger: Unified logging system
//   - ClawdLogViewerView: SwiftUI log viewer
//   - ClawdDeveloperMenuModifier: Developer menu view modifier
//
// Backup:
//   - ClawdBackupKit: Backup and restore utilities
//
// Theme System:
//   - Theme / ThemeColor: Codable theme + per-mode color tokens
//   - ThemePalette: 8 pre-designed themes (Default, Midnight, Ocean, Sunset,
//     Forest, Paper, Aurora, Monochrome)
//   - ThemeManager: @MainActor controller, syncs via NSUbiquitousKeyValueStore,
//     swaps alternate app icons via UIApplication.setAlternateIconName
//   - ThemePickerView: drop-in SwiftUI grid picker
//   - View.themed(_:) modifier + @Environment(\.theme) access
