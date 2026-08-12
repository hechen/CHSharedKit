import Foundation

enum CHSharedKitPrivacyManifestResource {
    static var url: URL? {
        Bundle.module.url(forResource: "PrivacyInfo", withExtension: "xcprivacy")
    }
}
