import XCTest
@testable import ErrandDesktop

// MARK: - GitHub Releases endpoint

@MainActor
final class UpdateCheckerTests: XCTestCase {

    /// The repo path was previously `errand/errand-desktop`, which 404s silently and
    /// meant no user ever saw an update notification. The cask's livecheck and the
    /// in-app checker must both point at the same repository.
    func testRepoPathTargetsErrandAIOrg() {
        XCTAssertEqual(UpdateChecker.repoPath, "errand-ai/errand-desktop")
    }

    func testLatestReleaseURLTargetsErrandAIOrg() throws {
        let url = try XCTUnwrap(UpdateChecker.latestReleaseURL)
        XCTAssertEqual(
            url.absoluteString,
            "https://api.github.com/repos/errand-ai/errand-desktop/releases/latest"
        )
        XCTAssertEqual(url.host, "api.github.com")
        XCTAssertEqual(url.path, "/repos/errand-ai/errand-desktop/releases/latest")
    }
}
