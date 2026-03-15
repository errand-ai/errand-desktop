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
}
