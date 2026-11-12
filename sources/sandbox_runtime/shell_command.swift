import Foundation

// Classify simple argv only; complex shell syntax remains one shell task.
public func shellCommandArguments(_ line: String) -> [String] {
    var words: [String] = [], word = "", quote: Character?, escaped = false, started = false
    for character in line {
        if escaped {
            if character == "\n" { return ["/bin/sh", "-c", line] }
            if quote == "\"", !"$`\"\\".contains(character) { word.append("\\") }
            word.append(character); escaped = false; started = true; continue
        }
        if character == "\\", quote != "'" { escaped = true; started = true; continue }
        if let current = quote {
            if character == current { quote = nil }
            else {
                if current == "\"", "$`".contains(character) { return ["/bin/sh", "-c", line] }
                word.append(character)
            }
            continue
        }
        if character == "'" || character == "\"" { quote = character; started = true; continue }
        if character == "#", !started { break }
        if "|;&<>$`*?[]~(){}\n".contains(character) { return ["/bin/sh", "-c", line] }
        if character == " " || character == "\t" {
            if started { words.append(word); word = ""; started = false }
        } else { word.append(character); started = true }
    }
    if quote != nil || escaped { return ["/bin/sh", "-c", line] }
    if started { words.append(word) }
    if words.first?.contains("=") == true { return ["/bin/sh", "-c", line] }
    return words
}

// Static shell lists only. Never execute a shell to discover what it might run.
// nil means dynamic/unsupported syntax and therefore a serial allowlist task.
public func shellCommandList(_ line: String) -> [[String]]? {
    enum Token { case word(String), separator(String), redirect(String) }
    // CRLF is one Swift Character but two shell characters.
    let chars = line.unicodeScalars.map { Character(String($0)) }
    var tokens: [Token] = [], word = "", started = false, quoted = false, quote: Character?
    var i = 0
    func flush() {
        if started { tokens.append(.word(word)); word = ""; started = false; quoted = false }
    }
    while i < chars.count {
        let c = chars[i]
        if c == "\0" { return nil }
        if c == "\\", quote != "'" {
            guard i + 1 < chars.count else { return nil }
            let next = chars[i + 1]
            if next == "\n" { i += 2; continue }
            if quote == "\"", !"$`\"\\".contains(next) { word.append(c); i += 1; continue }
            word.append(next); started = true; quoted = true; i += 2; continue
        }
        if let current = quote {
            if c == current { quote = nil }
            else {
                if current == "\"", "$`".contains(c) { return nil }
                word.append(c)
            }
            i += 1; continue
        }
        if c == "'" || c == "\"" { quote = c; started = true; quoted = true; i += 1; continue }
        if c == "#", !started {
            while i < chars.count && chars[i] != "\n" { i += 1 }
            continue
        }
        if "$`*?[]~(){}".contains(c) { return nil }
        if c == " " || c == "\t" { flush(); i += 1; continue }
        if c == "<" || c == ">" {
            // An adjacent, unquoted IO number is not a command argument.
            if started && !quoted && !word.isEmpty && word.allSatisfy({ $0 >= "0" && $0 <= "9" }) {
                word = ""; started = false
            }
            flush()
            var op = String(c); i += 1
            if i < chars.count && chars[i] == c {
                guard c == ">" else { return nil } // heredoc/here-string
                op.append(chars[i]); i += 1
            } else if i < chars.count && chars[i] == "&" { op.append(chars[i]); i += 1 }
            tokens.append(.redirect(op)); continue
        }
        if ";&|\n".contains(c) {
            flush()
            var op = String(c); i += 1
            if i < chars.count && chars[i] == c && (c == "&" || c == "|") { op.append(chars[i]); i += 1 }
            guard op != "&" else { return nil } // background jobs
            tokens.append(.separator(op)); continue
        }
        word.append(c); started = true; i += 1
    }
    guard quote == nil else { return nil }
    flush()
    var commands: [[String]] = [], argv: [String] = [], redirection: String?
    var needsCommand = false
    // These alter shell state, launch dynamically or form compound grammar.
    let unsupported = Set(["!", "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "select", "function", "time", "coproc", "cd", "pushd", "popd", "export", "unset", "set", "shopt", "alias", "unalias", "eval", "exec", ".", "source", "command", "builtin", "enable", "trap", "read", "hash", "typeset", "declare", "local", "readonly", "return", "exit", "break", "continue", "wait"])
    func finish() -> Bool {
        guard let first = argv.first, !first.isEmpty, !first.contains("="), !unsupported.contains(first) else { return false }
        commands.append(argv); argv = []; return true
    }
    for token in tokens {
        switch token {
        case .word(let value):
            if let op = redirection {
                if op.hasSuffix("&") && value != "-" && (value.isEmpty || !value.allSatisfy({ $0 >= "0" && $0 <= "9" })) { return nil }
                redirection = nil
            } else { argv.append(value) }
        case .redirect(let op):
            guard redirection == nil else { return nil }
            redirection = op
        case .separator(let op):
            guard redirection == nil else { return nil }
            if op == "\n" && argv.isEmpty { continue }
            guard finish() else { return nil }
            needsCommand = op != ";" && op != "\n"
        }
    }
    guard redirection == nil else { return nil }
    if !argv.isEmpty { guard finish() else { return nil } }
    else if needsCommand { return nil }
    return commands.isEmpty ? nil : commands
}

// Called inside the Host/helper, with the executing sandbox's cwd and PATH.
// Safe builtins use their standard external equivalent for policy matching.
public func shellExecutable(_ name: String, environment: [String: String], cwd: String) -> String? {
    let builtins = ["echo": "/bin/echo", "pwd": "/bin/pwd", "test": "/bin/test",
                    "printf": "/usr/bin/printf", "true": "/usr/bin/true", "false": "/usr/bin/false"]
    if let builtin = builtins[name] { return builtin }
    func absolute(_ value: String) -> String {
        "/" + (value.hasPrefix("/") ? value : cwd + "/" + value).split(separator: "/").filter { $0 != "." }.joined(separator: "/")
    }
    guard !name.split(separator: "/").contains("..") else { return nil }
    if !name.contains("/"), (environment["PATH"] ?? "").split(separator: ":").contains(where: { $0.split(separator: "/").contains("..") }) { return nil }
    let candidates = name.contains("/") ? [absolute(name)] : (environment["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: false).map {
        absolute($0.isEmpty ? name : String($0) + "/" + name)
    }
    // Inherited helpers may report the operator's home through Foundation.
    // Use the actual container root supplied by the Host, not that larger tree.
    let mutableRoots = ([cwd]
        + [environment["METAL_SANDBOX_CONTAINER_HOME"], environment["HOME"], environment["TMPDIR"], environment["METAL_SANDBOX_BRIDGE_DIRECTORY"].map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }].compactMap { $0 })
        .flatMap { [absolute($0), URL(fileURLWithPath: $0).resolvingSymlinksInPath().path] }
    for candidate in candidates {
        if !name.contains("/") {
            let directory = URL(fileURLWithPath: candidate).deletingLastPathComponent()
            let paths = [directory.path, directory.resolvingSymlinksInPath().path]
            // An earlier command can create/delete a PATH entry in the container,
            // changing which binary runs. Require an explicit path in that case.
            if paths.contains(where: { path in mutableRoots.contains { path == $0 || path.hasPrefix($0 + "/") } }) { return nil }
        }
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath: candidate, isDirectory: &directory) && !directory.boolValue
            && FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
}
