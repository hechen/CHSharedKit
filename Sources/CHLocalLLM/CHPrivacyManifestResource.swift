import Foundation

enum CHLocalLLMPrivacyManifestResource {
    static var url: URL? {
        Bundle.module.url(forResource: "PrivacyInfo", withExtension: "xcprivacy")
    }
}
