#if canImport(WebKit)
import Foundation
import Observation
import WebKit

/// A dedicated local WebKit profile for the user's Amazon sign-in.
///
/// Cookies and website data stay in this store on the device so the user can
/// return without signing in each time. Product and photo browsers should keep
/// using ephemeral stores. Hosts observe `generation` to tear down web views
/// after the store is cleared.
@MainActor @Observable
public final class AmazonBrowserSession {
    public let dataStore: WKWebsiteDataStore
    public private(set) var clearing = false
    public private(set) var generation = 0
    public private(set) var acknowledged: Bool
    private let defaults: UserDefaults?
    private let acknowledgementKey: String

    /// - Parameters:
    ///   - dataStore: Use `WKWebsiteDataStore(forIdentifier:)` with an app-stable UUID
    ///     for a persistent sign-in, or `.nonPersistent()` for tests.
    ///   - defaults: Where the one-time local-sign-in acknowledgement is remembered.
    public init(dataStore: WKWebsiteDataStore, defaults: UserDefaults? = nil,
                acknowledgementKey: String = "amazonLocalSignInAcknowledged") {
        self.dataStore = dataStore
        self.defaults = defaults
        self.acknowledgementKey = acknowledgementKey
        acknowledged = defaults?.bool(forKey: acknowledgementKey) ?? false
    }

    public func acknowledge() {
        acknowledged = true
        defaults?.set(true, forKey: acknowledgementKey)
    }

    /// Removes every cookie and site record in the profile.
    public func clear() async {
        guard !clearing else { return }
        clearing = true
        // Let active import views cancel reads and detach their previous web views first.
        generation += 1
        await Task.yield()
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        acknowledged = false
        defaults?.removeObject(forKey: acknowledgementKey)
        clearing = false
    }

    /// A `WKWebView` configured for reading Amazon's desktop order pages in this profile.
    public func makeWebView(customUserAgent: String? = nil) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.upgradeKnownHostsToHTTPS = true
        #if os(iOS)
        // The order selectors target Amazon's desktop layouts.
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        #endif
        let webView = WKWebView(frame: .zero, configuration: configuration)
        if let customUserAgent { webView.customUserAgent = customUserAgent }
        webView.allowsBackForwardNavigationGestures = true
        return webView
    }
}
#endif
