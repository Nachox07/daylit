// What the app decided and did: ~/Library/Logs/Daylit/daylit.log (also stdout with DAYLIT_DEBUG=1).
import Foundation

let DEBUG = ProcessInfo.processInfo.environment["DAYLIT_DEBUG"] == "1"
/// Debug detail: stdout only, with DAYLIT_DEBUG=1.
func log(_ s: @autoclosure () -> String) { if DEBUG { print("[daylit] " + s()); fflush(stdout) } }

/// What the app decided and did, in ~/Library/Logs/Daylit/daylit.log (also stdout with DAYLIT_DEBUG=1).
enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Daylit/daylit.log")
    static let q = DispatchQueue(label: "log")
    static let fmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()
    static func write(_ msg: String) {
        log(msg)
        let line = fmt.string(from: Date()) + " " + msg + "\n"
        q.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 512 * 1024 {
                let old = url.appendingPathExtension("old")
                try? fm.removeItem(at: old); try? fm.moveItem(at: url, to: old)
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
