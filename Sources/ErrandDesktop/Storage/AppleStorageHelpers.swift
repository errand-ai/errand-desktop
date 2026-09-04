import Foundation
import ContainerizationEXT4
import SystemPackage

/// Ext4 disk image support for the Apple Containerization runtime.
///
/// Postgres and Valkey need full filesystem control (chown, chmod), which virtiofs
/// shares cannot provide, so under Apple Containerization they are backed by ext4
/// block devices instead. Docker uses named volumes and never reaches this code.
///
/// This lives apart from `StorageManager` so that `StorageManager` — which every
/// runtime uses — carries no `ContainerizationEXT4` dependency and stays callable
/// on macOS 15, where Apple Containerization is unavailable.
@available(macOS 26, *)
extension StorageManager {

    /// Returns the path to a service's ext4 disk image, creating it if needed.
    func ensureDataDisk(for serviceId: String, sizeInMB: Int) throws -> String {
        let fm = FileManager.default
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
}
