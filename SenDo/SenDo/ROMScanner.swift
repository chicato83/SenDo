import Foundation

// MARK: - ROM Folder Scanner

/// Recursive scan of the user-configured ROM folder.
///
/// Deliberately free of actor isolation so `USBManager` can run it on a
/// background queue: a library on an external volume can take a while and must
/// never block the main thread.
enum ROMScanner {
    /// Extensions Sphaira is able to install (matched case-insensitively).
    static let supportedExtensions: Set<String> = ["nsp", "xci", "nsz", "xcz"]

    /// `[010070201D1BA000]` -> `010070201D1BA000`.
    private static let titleIdRegex = try! NSRegularExpression(pattern: "\\[([0-9A-Fa-f]{16})\\]")
    /// `[v589824]` -> `589824`.
    private static let versionRegex = try! NSRegularExpression(pattern: "\\[v(\\d+)\\]")

    /// Returns every supported file below `folderPath`, hidden items excluded.
    static func scan(folderPath: String) -> [GameFile] {
        let root = URL(fileURLWithPath: folderPath, isDirectory: true)
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        ) else {
            SenDoLog.log("ROMScanner: unable to enumerate \(root.path)")
            return []
        }

        var results: [GameFile] = []
        var rejected = 0

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isHiddenKey])
            guard values?.isRegularFile == true, values?.isHidden != true else { continue }

            let pathExtension = url.pathExtension
            guard supportedExtensions.contains(pathExtension.lowercased()) else { continue }

            let name = url.lastPathComponent
            guard let path = normalizedPath(of: url) else {
                rejected += 1
                continue
            }

            results.append(
                GameFile(
                    name: name,
                    path: path,
                    titleId: titleId(in: name),
                    size: Int64(values?.fileSize ?? 0),
                    version: version(in: name),
                    type: GameFileType(pathExtension: pathExtension),
                    isSelected: false
                )
            )
        }

        SenDoLog.log("ROMScanner: \(results.count) file(s) under \(root.path) (\(rejected) skipped)")
        return results
    }

    // MARK: Filename parsing

    /// First bracketed 16-hex-digit run, e.g. `[010070201D1BA000]`.
    static func titleId(in fileName: String) -> String {
        firstCapture(of: titleIdRegex, in: fileName) ?? ""
    }

    /// First bracketed version run, e.g. `[v589824]`; `nil` when absent.
    static func version(in fileName: String) -> Int? {
        firstCapture(of: versionRegex, in: fileName).flatMap(Int.init)
    }

    private static func firstCapture(of regex: NSRegularExpression, in string: String) -> String? {
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        guard let match = regex.firstMatch(in: string, range: range),
              let capture = Range(match.range(at: 1), in: string) else { return nil }
        return String(string[capture])
    }

    /// Absolute, trailing-slash-free path — this becomes `GameFile.id`.
    private static func normalizedPath(of url: URL) -> String? {
        guard url.isFileURL else { return nil }
        return url.standardizedFileURL.path
    }
}
