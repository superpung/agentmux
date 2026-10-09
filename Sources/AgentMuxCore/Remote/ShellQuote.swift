/// POSIX shell quoting for words that a remote `sh`/`bash` will parse.
///
/// ssh joins its remote command into one string and the remote login shell
/// parses it, so argv safety on the Mac side does not carry over. Every word
/// is single-quoted unless it is made only of characters no shell treats
/// specially.
public enum ShellQuote {
    public static func word(_ value: String) -> String {
        if !value.isEmpty, value.unicodeScalars.allSatisfy(isPlain) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func command(_ argv: [String]) -> String {
        argv.map(word).joined(separator: " ")
    }

    private static func isPlain(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a" ... "z", "A" ... "Z", "0" ... "9", "-", "_", ".", "/", ":", "@", "%", "+", ",", "=":
            true
        default:
            false
        }
    }
}
