import Foundation

/// mkdir-based lock, compatible with the hook script's `acquire_lock`.
struct DirectoryLock {
    let url: URL

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        acquire()
        defer { release() }
        return try body()
    }

    private func acquire() {
        var tries = 0
        while mkdir(url.path, 0o755) != 0 {
            if errno == ENOENT {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                continue
            }
            tries += 1
            if tries >= 500 {
                // ~5s without progress: assume a writer was killed while holding the lock
                rmdir(url.path)
                tries = 0
            }
            usleep(10_000)
        }
    }

    private func release() {
        rmdir(url.path)
    }
}
