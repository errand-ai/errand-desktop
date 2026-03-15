import Foundation

extension Bundle {
    /// Locates the ErrandDesktop resource bundle.
    ///
    /// Checks (in order):
    /// 1. Contents/Resources/ inside the app bundle (standard macOS app layout)
    /// 2. Next to the app bundle root (SPM flat layout / development)
    /// 3. Next to the executable in the build directory (swift build / swift test)
    static let module: Bundle = {
        let bundleName = "ErrandDesktop_ErrandDesktop"

        let candidates: [URL?] = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            Bundle.main.executableURL?.deletingLastPathComponent(),
        ]

        for candidate in candidates {
            guard let dir = candidate else { continue }
            let bundleURL = dir.appendingPathComponent(bundleName + ".bundle")
            if let bundle = Bundle(url: bundleURL) {
                return bundle
            }
        }

        // Fallback: search common build output directories relative to the executable
        if let execURL = Bundle.main.executableURL {
            let buildDir = execURL.deletingLastPathComponent()
            let bundleURL = buildDir.appendingPathComponent(bundleName + ".bundle")
            if let bundle = Bundle(url: bundleURL) {
                return bundle
            }
        }

        fatalError("Could not load resource bundle '\(bundleName)'. Ensure the Resources are included in the app bundle.")
    }()
}
