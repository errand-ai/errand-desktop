import Foundation
import ContainerizationEXT4
import SystemPackage

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

    // MARK: - Data Directories

    /// Creates the data directories for container volumes.
    func ensureDataDirectories() {
        let subdirs = ["litellm"]
        for sub in subdirs {
            let dir = dataDir.appendingPathComponent(sub)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Also ensure the disks directory exists
        try? fm.createDirectory(at: dataDir.appendingPathComponent("disks"), withIntermediateDirectories: true)
    }

    /// Returns the host path for a service's data volume (virtiofs shares).
    func dataPath(for serviceId: String) -> String {
        dataDir.appendingPathComponent(serviceId).path
    }

    // MARK: - Ext4 Disk Images

    /// Returns the path to a service's ext4 disk image, creating it if needed.
    /// Used for services like postgres and valkey that need full filesystem control.
    func ensureDataDisk(for serviceId: String, sizeInMB: Int) throws -> String {
        let disksDir = dataDir.appendingPathComponent("disks")
        try fm.createDirectory(at: disksDir, withIntermediateDirectories: true)

        let diskPath = disksDir.appendingPathComponent("\(serviceId).img")

        if fm.fileExists(atPath: diskPath.path) {
            print("[StorageManager] Using existing disk image: \(diskPath.path)")
            return diskPath.path
        }

        print("[StorageManager] Creating \(sizeInMB)MB ext4 disk image for \(serviceId)...")
        let sizeInBytes = UInt64(sizeInMB) * 1024 * 1024
        let filePath = FilePath(diskPath.path)
        let formatter = try EXT4.Formatter(filePath, minDiskSize: sizeInBytes)
        try formatter.close()
        print("[StorageManager] Disk image created: \(diskPath.path)")

        return diskPath.path
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
