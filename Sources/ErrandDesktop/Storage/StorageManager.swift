import Foundation

/// Manages persistent storage in ~/Library/Application Support/ErrandDesktop/
class StorageManager {
    private let fm = FileManager.default

    /// Root application support directory.
    private let appSupportDir: URL

    /// Data directory for container volume mounts.
    /// Internal (not private) so `AppleStorageHelpers` can reach it.
    let dataDir: URL

    /// Path to the persisted config.json file.
    private let configFileURL: URL

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ErrandDesktop")
        self.appSupportDir = base
        self.dataDir = base.appendingPathComponent("data")
        self.configFileURL = base.appendingPathComponent("config.json")
    }

    // MARK: - Data Directories

    /// Creates the data directories for container volumes.
    func ensureDataDirectories() {
        let subdirs = ["postgres", "valkey", "litellm", "hindsight"]
        for sub in subdirs {
            let dir = dataDir.appendingPathComponent(sub)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Also ensure the disks directory exists
        try? fm.createDirectory(at: dataDir.appendingPathComponent("disks"), withIntermediateDirectories: true)

        // Write default LiteLLM config if not present
        let litellmConfig = dataDir.appendingPathComponent("litellm/config.yaml")
        if !fm.fileExists(atPath: litellmConfig.path) {
            let defaultConfig = """
            general_settings:
              store_model_in_db: true
              store_prompts_in_spend_logs: true
              master_key: os.environ/PROXY_MASTER_KEY
              database_connection_pool_limits: 10
              allow_requests_on_db_unavailable: True

            litellm_settings:
              request_timeout: 600
              set_verbose: False
              json_logs: false
            """
            try? defaultConfig.write(to: litellmConfig, atomically: true, encoding: .utf8)
        }
    }

    /// Returns the host path for a service's data volume (virtiofs shares).
    func dataPath(for serviceId: String) -> String {
        dataDir.appendingPathComponent(serviceId).path
    }

    // MARK: - Config Persistence

    /// Loads and decodes the persisted AppConfig from config.json.
    func loadConfig() -> AppConfig? {
        guard let data = try? Data(contentsOf: configFileURL) else { return nil }
        return try? JSONDecoder().decode(AppConfig.self, from: data)
    }

    /// Encodes and writes the AppConfig to config.json.
    func saveConfig(_ config: AppConfig) {
        do {
            try fm.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: configFileURL, options: .atomic)
        } catch {
            print("[StorageManager] Failed to save config: \(error)")
        }
    }

    // MARK: - Reset Data

    /// Deletes all container data (including disk images) and recreates empty directories.
    func resetData() {
        try? fm.removeItem(at: dataDir)
        ensureDataDirectories()
    }
}
