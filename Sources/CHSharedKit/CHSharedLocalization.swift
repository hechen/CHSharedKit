import Foundation

/// Package-owned default copy. Explicit caller strings remain unchanged.
public enum CHSharedLocalization {
    public static func string(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: .module)
    }
}
