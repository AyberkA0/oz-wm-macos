import Foundation

enum Log {
    static var debugEnabled = false
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/OzWM.log")

    private static let queue = DispatchQueue(label: "oz.log")
    /// Over this the log moves to OzWM.old.log and starts again (also while running: Oz is
    /// meant to stay open for weeks).
    private static let maxSize: UInt64 = 2_000_000
    private static var handle: FileHandle? = open()

    private static func open() -> FileHandle? {
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? NSNumber, size.uint64Value > maxSize {
            rotate()
        }
        // Appending: `OzWM msg`, `--check-config` and a second copy write to the same file,
        // and each writing where it last was wrote over the others' lines.
        let fd = Darwin.open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return nil }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        h.seekToEndOfFile()
        return h
    }

    private static func rotate() {
        let old = url.deletingLastPathComponent().appendingPathComponent("OzWM.old.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        // With the date: Oz runs for weeks, and a line may be read long after.
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            let data = Data(line.utf8)
            FileHandle.standardError.write(data)
            handle?.write(data)
            if let h = handle, h.offsetInFile > maxSize {
                try? h.close()
                rotate()
                handle = open()
            }
        }
    }

    /// Waits until everything logged so far is written (before exiting).
    static func flush() { queue.sync {} }

    static func debug(_ message: @autoclosure () -> String) {
        if debugEnabled { info("[debug] " + message()) }
    }
}
