import Foundation

/// Manages persistent storage in ~/Library/Application Support/ErrandDesktop/
class StorageManager {
    private let fm = FileManager.default

    /// Root application support directory.
    private let appSupportDir: URL

    /// Data directory for container volume mounts.
    private let dataDir: URL

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

    // MARK: - Data Directories (Task 4.1)

    /// Creates the data directories for PostgreSQL, Valkey, and LiteLLM volumes.
    func ensureDataDirectories() {
        let subdirs = ["postgres", "valkey", "litellm"]
        for sub in subdirs {
            let dir = dataDir.appendingPathComponent(sub)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Returns the host path for a service's data volume.
    func dataPath(for serviceId: String) -> String {
        dataDir.appendingPathComponent(serviceId).path
    }

    // MARK: - Config Persistence (Task 4.4)

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

    // MARK: - Reset Data (Task 4.5)

    /// Deletes all container data and recreates empty directories.
    func resetData() {
        try? fm.removeItem(at: dataDir)
        ensureDataDirectories()
    }
}
