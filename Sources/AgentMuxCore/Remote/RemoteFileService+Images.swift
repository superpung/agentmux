import Foundation

extension RemoteFileService {
    /// The most image files one preview fetches.
    public static let imageBatchCount = 64
    /// The most image bytes one preview fetches in all.
    public static let imageBatchByteCap = 32 * 1024 * 1024

    /// Reads the image files a preview shows (the pictures in a Markdown or
    /// HTML file) in one session: each regular file up to `imageByteCap`,
    /// `imageBatchByteCap` in all, the first `imageBatchCount` paths.
    /// Read-only. A file missing, unreadable, not a regular file, too large,
    /// or past the total is left out of the result.
    public static func readImages(
        _ paths: [String], host: HostConfig, target: TargetConfig, options: SSHOptions = SSHOptions()
    ) async -> [String: Data] {
        let paths = Array(paths.prefix(imageBatchCount))
        guard !paths.isEmpty else { return [:] }
        let result = await RemoteScript.run(imagesScript(paths), host: host, target: target, options: options,
                                            timeoutSeconds: 90,
                                            stdoutLimit: base64OutputLimit(imageBatchByteCap) + paths.count * 32)
        guard case let .success(output) = result else { return [:] }
        return parseImages(stripFraming(output), paths: paths)
    }

    /// One `@@img <size>` line a path, in order, followed by the file as one
    /// line of base64; `@@img -1` for a file left out. A FIFO or device is
    /// never opened: only regular files are read.
    static func imagesScript(_ paths: [String], cap: Int = imageByteCap, total: Int = imageBatchByteCap) -> String {
        """
        left=\(total)
        for f in \(ShellQuote.command(paths)); do
          sz=
          if [ -f "$f" ] && [ -r "$f" ]; then sz=$(wc -c < "$f" 2>/dev/null | tr -d ' '); fi
          if [ -n "$sz" ] && [ "$sz" -le \(cap) ] 2>/dev/null && [ "$sz" -le "$left" ]; then
            left=$((left - sz))
            printf '@@img %s\\n' "$sz"
            base64 < "$f" | tr -d '\\n'
            printf '\\n'
          else
            printf '@@img -1\\n'
          fi
        done
        """
    }

    static func parseImages(_ output: String, paths: [String]) -> [String: Data] {
        var images: [String: Data] = [:]
        var index = 0
        var expecting = false
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@img ") {
                expecting = (Int(line.dropFirst(6).trimmingCharacters(in: .whitespaces)) ?? -1) >= 0
                index += 1
            } else if expecting {
                expecting = false
                if index - 1 < paths.count, let data = Data(base64Encoded: String(line)), !data.isEmpty {
                    images[paths[index - 1]] = data
                }
            }
        }
        return images
    }
}
