import XCTest
@testable import ErrandDesktop

// MARK: - AppConfig Serialization

final class AppConfigTests: XCTestCase {
    func testDefaultValues() {
        let config = AppConfig()
        XCTAssertFalse(config.useGoogleDrive)
        XCTAssertFalse(config.useOneDrive)
        XCTAssertTrue(config.useHindsight)
        XCTAssertTrue(config.deployLiteLLM)
    }

    func testRoundTripSerialization() throws {
        var config = AppConfig()
        config.useGoogleDrive = true
        config.useOneDrive = true

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

        XCTAssertTrue(decoded.useGoogleDrive)
        XCTAssertTrue(decoded.useOneDrive)
    }

    func testBackwardsCompatibility() throws {
        // Simulates loading a config.json that was saved before cloud storage fields existed
        let json = """
        {"deployLiteLLM": true, "backendPort": 8000, "postgresPort": 5432, "valkeyPort": 6379, "litellmPort": 4000, "hindsightPort": 9999, "useHindsight": true, "containerRuntime": "docker", "launchAtLogin": false, "contentManagerImageTag": "latest", "showBetaVersions": false, "llmProviderName": "", "llmProviderBaseURL": "", "llmProviderAPIKey": "", "llmProviderType": "", "hindsightLLMModel": "", "hindsightEmbeddingModel": ""}
        """
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        // New fields should default to false when missing from JSON
        XCTAssertFalse(config.useGoogleDrive)
        XCTAssertFalse(config.useOneDrive)
    }
}

// MARK: - Service Dependency Graph

final class ServiceDependencyTests: XCTestCase {
    func testCloudStorageServicesHaveNoDependencies() {
        XCTAssertEqual(serviceDependencies["gdrive-mcp"], [])
        XCTAssertEqual(serviceDependencies["onedrive-mcp"], [])
    }

    func testCloudStorageServicesInDependencyGraph() {
        XCTAssertNotNil(serviceDependencies["gdrive-mcp"])
        XCTAssertNotNil(serviceDependencies["onedrive-mcp"])
    }

    func testShutdownOrderIncludesCloudStorage() {
        let groups = serviceShutdownOrder()
        let allServices = groups.flatMap { $0 }
        XCTAssertTrue(allServices.contains("gdrive-mcp"))
        XCTAssertTrue(allServices.contains("onedrive-mcp"))
    }

    func testCloudStorageShutdownBeforeDependentServices() {
        // Cloud storage services have no dependents, so they should be in the last
        // shutdown group (depth 0, which is shut down last)
        let groups = serviceShutdownOrder()
        guard let lastGroup = groups.last else {
            XCTFail("No shutdown groups")
            return
        }
        // gdrive-mcp and onedrive-mcp have depth 0 (no dependencies), same as postgres/valkey
        XCTAssertTrue(lastGroup.contains("gdrive-mcp"))
        XCTAssertTrue(lastGroup.contains("onedrive-mcp"))
    }

    func testPlaywrightHasNoDependencies() {
        // Playwright is a leaf service that starts in the first wave alongside
        // postgres/valkey, so it has time to boot Xvfb + Chromium before backend
        // is created. See backend->playwright dependency below.
        XCTAssertEqual(serviceDependencies["playwright"], [])
    }

    func testBackendDependsOnPlaywright() {
        // Backend's PLAYWRIGHT_MCP_URL env var is only injected at container
        // creation time. Without this dependency, backend could be built before
        // Playwright is healthy, leaving the URL pointing at a not-yet-listening
        // server for the lifetime of the backend container.
        let backendDeps = serviceDependencies["backend"] ?? []
        XCTAssertTrue(
            backendDeps.contains("playwright"),
            "backend must wait for playwright so PLAYWRIGHT_MCP_URL points at a healthy listener"
        )
    }

    func testPlaywrightShutdownAfterBackend() {
        // Backend depends on playwright, so backend must be in an earlier shutdown
        // group (higher depth, shut down first) than playwright.
        let groups = serviceShutdownOrder()
        var backendGroupIndex: Int?
        var playwrightGroupIndex: Int?
        for (idx, group) in groups.enumerated() {
            if group.contains("backend") { backendGroupIndex = idx }
            if group.contains("playwright") { playwrightGroupIndex = idx }
        }
        guard let backendIdx = backendGroupIndex, let playwrightIdx = playwrightGroupIndex else {
            XCTFail("backend or playwright missing from shutdown order")
            return
        }
        XCTAssertLessThan(
            backendIdx, playwrightIdx,
            "backend must shut down before playwright (it depends on it)"
        )
    }
}
