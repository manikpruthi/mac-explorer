import CoreServices
import Foundation

/// A parsed search box query.
///
/// Plain words must all appear in the name (case- and accent-insensitive); `*` and `?` turn a word
/// into a whole-name wildcard (`*.swift`); `"quoted text"` matches literally. Filters:
/// `kind:` / `type:`, `ext:`, `size:`, `modified:` / `datemodified:`, and `content:`.
struct SearchQuery: Sendable, Equatable {
    var terms: [String] = []
    var kinds: Set<FileKind> = []
    var extensions: Set<String> = []
    var minSize: Int64?
    var maxSize: Int64?
    var modifiedAfter: Date?
    var modifiedBefore: Date?
    var content: [String] = []

    var hasFilters: Bool {
        !kinds.isEmpty || !extensions.isEmpty || minSize != nil || maxSize != nil
            || modifiedAfter != nil || modifiedBefore != nil
    }

    var isEmpty: Bool { terms.isEmpty && content.isEmpty && !hasFilters }

    // MARK: Parsing

    static func parse(_ text: String, now: Date = Date()) -> SearchQuery {
        var query = SearchQuery()
        for token in tokenize(text) {
            if token.quoted {
                let folded = fold(token.text)
                if !folded.isEmpty { query.terms.append(escapeWildcards(folded)) }
                continue
            }
            guard let colon = token.text.firstIndex(of: ":"), colon != token.text.startIndex else {
                query.terms.append(fold(token.text))
                continue
            }
            let key = token.text[..<colon].lowercased()
            let value = String(token.text[token.text.index(after: colon)...])
            if !query.apply(key: key, value: value, now: now) {
                query.terms.append(fold(token.text))
            }
        }
        return query
    }

    private mutating func apply(key: String, value: String, now: Date) -> Bool {
        let lowered = value.lowercased()
        switch key {
        case "kind", "type":
            if let kinds = Self.kindAliases[lowered] {
                self.kinds.formUnion(kinds)
                return true
            }
            if key == "type", !lowered.isEmpty {
                extensions.insert(lowered.trimmingCharacters(in: CharacterSet(charactersIn: ".")))
                return true
            }
            return false
        case "ext", "extension":
            let parts = lowered.split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }
            let valid = parts.filter { !$0.isEmpty }
            guard !valid.isEmpty else { return false }
            extensions.formUnion(valid)
            return true
        case "size":
            return applySize(lowered)
        case "modified", "datemodified", "date":
            return applyDate(lowered, now: now)
        case "content", "contains":
            let folded = Self.fold(value)
            guard !folded.isEmpty else { return false }
            content.append(folded)
            return true
        case "name":
            let folded = Self.fold(value)
            guard !folded.isEmpty else { return false }
            terms.append(folded)
            return true
        default:
            return false
        }
    }

    private static let kindAliases: [String: Set<FileKind>] = [
        "folder": [.folder], "folders": [.folder], "directory": [.folder],
        "image": [.image], "images": [.image], "picture": [.image], "pictures": [.image], "photo": [.image],
        "video": [.video], "videos": [.video], "movie": [.video],
        "audio": [.audio], "music": [.audio], "sound": [.audio],
        "pdf": [.pdf],
        "document": [.word, .pdf, .text, .excel, .powerpoint], "documents": [.word, .pdf, .text, .excel, .powerpoint],
        "doc": [.word], "word": [.word],
        "spreadsheet": [.excel], "excel": [.excel],
        "presentation": [.powerpoint], "powerpoint": [.powerpoint],
        "archive": [.archive], "zip": [.archive], "compressed": [.archive],
        "code": [.code], "source": [.code],
        "text": [.text],
        "app": [.app], "apps": [.app], "application": [.app], "program": [.app],
        "font": [.font],
        "disk": [.disk], "diskimage": [.disk],
    ]

    /// Windows size buckets plus comparisons like `>10MB`, `<=500kb`, `1g`.
    private mutating func applySize(_ value: String) -> Bool {
        let buckets: [String: (Int64?, Int64?)] = [
            "empty": (0, 0),
            "tiny": (0, 16_000),
            "small": (16_000, 1_000_000),
            "medium": (1_000_000, 128_000_000),
            "large": (128_000_000, 1_000_000_000),
            "huge": (1_000_000_000, 4_000_000_000),
            "gigantic": (4_000_000_000, nil),
        ]
        if let bucket = buckets[value] {
            minSize = bucket.0
            maxSize = bucket.1
            return true
        }
        var rest = Substring(value)
        var op = ">="
        for candidate in [">=", "<=", ">", "<", "="] where rest.hasPrefix(candidate) {
            op = candidate
            rest = rest.dropFirst(candidate.count)
            break
        }
        guard let bytes = Self.parseBytes(String(rest)) else { return false }
        switch op {
        case ">": minSize = bytes + 1
        case ">=": minSize = bytes
        case "<": maxSize = max(0, bytes - 1)
        case "<=": maxSize = bytes
        default:
            minSize = bytes
            maxSize = bytes
        }
        return true
    }

    static func parseBytes(_ text: String) -> Int64? {
        let units: [(String, Double)] = [
            ("gb", 1e9), ("g", 1e9), ("mb", 1e6), ("m", 1e6), ("kb", 1e3), ("k", 1e3), ("bytes", 1), ("b", 1),
        ]
        var number = text.trimmingCharacters(in: .whitespaces)
        var multiplier = 1.0
        for (suffix, factor) in units where number.hasSuffix(suffix) {
            number.removeLast(suffix.count)
            multiplier = factor
            break
        }
        guard let value = Double(number), value >= 0 else { return nil }
        return Int64(value * multiplier)
    }

    private mutating func applyDate(_ value: String, now: Date) -> Bool {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        switch value {
        case "today":
            modifiedAfter = today
            return true
        case "yesterday":
            modifiedAfter = calendar.date(byAdding: .day, value: -1, to: today)
            modifiedBefore = today
            return true
        case "week", "thisweek":
            modifiedAfter = calendar.date(byAdding: .day, value: -7, to: today)
            return true
        case "month", "thismonth":
            modifiedAfter = calendar.date(byAdding: .month, value: -1, to: today)
            return true
        case "year", "thisyear":
            modifiedAfter = calendar.date(byAdding: .year, value: -1, to: today)
            return true
        default:
            break
        }
        var rest = Substring(value)
        var op = "="
        for candidate in [">=", "<=", ">", "<"] where rest.hasPrefix(candidate) {
            op = candidate
            rest = rest.dropFirst(candidate.count)
            break
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let day = formatter.date(from: String(rest)),
              let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { return false }
        switch op {
        case ">": modifiedAfter = nextDay
        case ">=": modifiedAfter = day
        case "<": modifiedBefore = day
        case "<=": modifiedBefore = nextDay
        default:
            modifiedAfter = day
            modifiedBefore = nextDay
        }
        return true
    }

    /// Splits on whitespace outside quotes. A token that starts with a quote is literal;
    /// `key:"two words"` keeps its filter meaning with the quoted value.
    private static func tokenize(_ text: String) -> [(text: String, quoted: Bool)] {
        var tokens: [(String, Bool)] = []
        var current = ""
        var inQuotes = false
        var startedQuoted = false
        var hasToken = false
        func flush() {
            if hasToken { tokens.append((current, startedQuoted)) }
            current = ""
            startedQuoted = false
            hasToken = false
        }
        for character in text {
            if character == "\"" {
                if !hasToken { startedQuoted = true }
                hasToken = true
                inQuotes.toggle()
            } else if character.isWhitespace && !inQuotes {
                flush()
            } else {
                current.append(character)
                hasToken = true
            }
        }
        flush()
        return tokens
    }

    static func fold(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private static func escapeWildcards(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "?", with: "\\?")
            .replacingOccurrences(of: "[", with: "\\[")
    }

    // MARK: Matching

    private static func isWildcard(_ term: String) -> Bool {
        var escaped = false
        for character in term {
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "*" || character == "?" { return true }
        }
        return false
    }

    private static func unescape(_ term: String) -> String {
        guard term.contains("\\") else { return term }
        var result = ""
        var escaped = false
        for character in term {
            if !escaped && character == "\\" { escaped = true; continue }
            escaped = false
            result.append(character)
        }
        return result
    }

    /// Greedy glob matching with only string indices, not character arrays or a DP table.
    private static func matchesGlob(_ pattern: String, _ name: String) -> Bool {
        // Keep libc's complete bracket/locale semantics for the existing ASCII case.
        if pattern.utf8.allSatisfy({ $0 < 128 }), name.utf8.allSatisfy({ $0 < 128 }) {
            return fnmatch(pattern, name, 0) == 0
        }
        var p = pattern.startIndex
        var n = name.startIndex
        var star: String.Index?
        var retry = n
        while n < name.endIndex {
            if p < pattern.endIndex {
                let token = pattern[p]
                var next = pattern.index(after: p)
                if token == "*" {
                    star = next
                    retry = n
                    p = next
                    continue
                }
                var matches = token == "?" || token == name[n]
                if token == "\\" {
                    matches = next < pattern.endIndex && pattern[next] == name[n]
                    if next < pattern.endIndex { next = pattern.index(after: next) }
                } else if token == "[", let bracket = matchesBracket(pattern, from: next, character: name[n]) {
                    matches = bracket.matches
                    next = bracket.next
                }
                if matches {
                    p = next
                    n = name.index(after: n)
                    continue
                }
            }
            guard let star, retry < name.endIndex else { return false }
            retry = name.index(after: retry)
            n = retry
            p = star
        }
        while p < pattern.endIndex, pattern[p] == "*" { p = pattern.index(after: p) }
        return p == pattern.endIndex
    }

    /// Brackets still consume one character: literals, ranges, negation, escapes and
    /// POSIX ASCII classes. An unclosed bracket is a literal, as in fnmatch.
    private static func matchesBracket(
        _ pattern: String, from start: String.Index, character: Character
    ) -> (matches: Bool, next: String.Index)? {
        var i = start
        var negated = false
        if i < pattern.endIndex, pattern[i] == "!" || pattern[i] == "^" {
            negated = true
            i = pattern.index(after: i)
        }
        var first = true
        var matched = false
        while i < pattern.endIndex {
            if pattern[i] == "]", !first {
                return (negated ? !matched : matched, pattern.index(after: i))
            }
            first = false
            var lower = pattern[i]
            i = pattern.index(after: i)
            if lower == "\\" {
                guard i < pattern.endIndex else { return nil }
                lower = pattern[i]
                i = pattern.index(after: i)
            } else if lower == "[", i < pattern.endIndex, pattern[i] == ":" {
                let classStart = pattern.index(after: i)
                var end = classStart
                while end < pattern.endIndex, pattern[end] != ":" { end = pattern.index(after: end) }
                guard end < pattern.endIndex else { return nil }
                let close = pattern.index(after: end)
                guard close < pattern.endIndex, pattern[close] == "]",
                      let classMatch = matchesASCIIClass(pattern[classStart..<end], character: character) else {
                    return nil
                }
                matched = matched || classMatch
                i = pattern.index(after: close)
                continue
            }
            if i < pattern.endIndex, pattern[i] == "-" {
                var end = pattern.index(after: i)
                if end < pattern.endIndex, pattern[end] != "]" {
                    if pattern[end] == "\\" { end = pattern.index(after: end) }
                    guard end < pattern.endIndex else { return nil }
                    let upper = pattern[end]
                    matched = matched || (lower <= character && character <= upper)
                    i = pattern.index(after: end)
                    continue
                }
            }
            matched = matched || lower == character
        }
        return nil
    }

    private static func matchesASCIIClass(_ name: Substring, character: Character) -> Bool? {
        let scalars = character.unicodeScalars
        let scalar = scalars.first!
        let ascii = scalars.count == 1 && scalar.value < 128
        let value = ascii ? Int32(scalar.value) : 0
        switch name {
        case "alnum": return ascii && isalnum(value) != 0
        case "alpha": return ascii && isalpha(value) != 0
        case "blank": return ascii && isblank(value) != 0
        case "cntrl": return ascii && iscntrl(value) != 0
        case "digit": return ascii && isdigit(value) != 0
        case "graph": return ascii && isgraph(value) != 0
        case "lower": return ascii && islower(value) != 0
        case "print": return ascii && isprint(value) != 0
        case "punct": return ascii && ispunct(value) != 0
        case "space": return ascii && isspace(value) != 0
        case "upper": return ascii && isupper(value) != 0
        case "xdigit": return ascii && isxdigit(value) != 0
        default: return nil
        }
    }

    /// Name-only check, used before the (cheaper to skip) stat.
    func matchesName(_ name: String) -> Bool {
        guard !terms.isEmpty else { return true }
        let folded = Self.fold(name)
        for term in terms {
            if Self.isWildcard(term) {
                if !Self.matchesGlob(term, folded) { return false }
            } else if !folded.contains(Self.unescape(term)) {
                return false
            }
        }
        return true
    }

    func matchesAttributes(_ entry: FileEntry) -> Bool {
        if !kinds.isEmpty && !kinds.contains(entry.kind) { return false }
        if !extensions.isEmpty {
            guard !entry.isDirectory, extensions.contains((entry.name as NSString).pathExtension.lowercased()) else {
                return false
            }
        }
        if minSize != nil || maxSize != nil {
            if entry.isDirectory { return false }
            if let minSize, entry.size < minSize { return false }
            if let maxSize, entry.size > maxSize { return false }
        }
        if let modifiedAfter, entry.modified < modifiedAfter { return false }
        if let modifiedBefore, entry.modified >= modifiedBefore { return false }
        return true
    }

    /// Lower is better: exact name, then prefix, then word start, then anywhere.
    func relevance(_ name: String) -> Int {
        guard let first = terms.first(where: { !Self.isWildcard($0) }).map(Self.unescape) else { return 2 }
        let folded = Self.fold(name)
        let base = (folded as NSString).deletingPathExtension
        if folded == first || base == first { return 0 }
        if folded.hasPrefix(first) { return 1 }
        if let range = folded.range(of: first) {
            let before = folded[folded.index(before: range.lowerBound)]
            if !before.isLetter && !before.isNumber { return 2 }
        }
        return 3
    }

    // MARK: Spotlight

    /// MDQuery string for the system Spotlight index, or nil when nothing can be pushed down.
    func spotlightQuery() -> String? {
        var clauses: [String] = []
        for term in terms {
            if Self.isWildcard(term) {
                // Spotlight only understands `*`; `?` is widened and re-checked by matchesName.
                let pattern = Self.spotlightEscape(term, keepWildcards: true).replacingOccurrences(of: "?", with: "*")
                clauses.append("kMDItemFSName == \"\(pattern)\"cd")
            } else {
                clauses.append("kMDItemFSName == \"*\(Self.spotlightEscape(Self.unescape(term), keepWildcards: false))*\"cd")
            }
        }
        for text in content {
            clauses.append("kMDItemTextContent == \"\(Self.spotlightEscape(text, keepWildcards: false))*\"cdw")
        }
        if let minSize { clauses.append("kMDItemFSSize >= \(minSize)") }
        if let maxSize { clauses.append("kMDItemFSSize <= \(maxSize)") }
        let iso = ISO8601DateFormatter()
        if let modifiedAfter { clauses.append("kMDItemFSContentChangeDate >= $time.iso(\(iso.string(from: modifiedAfter)))") }
        if let modifiedBefore { clauses.append("kMDItemFSContentChangeDate < $time.iso(\(iso.string(from: modifiedBefore)))") }
        let types = Set(kinds.compactMap { Self.contentTypes[$0] })
        if !types.isEmpty {
            clauses.append("(" + types.sorted().map { "kMDItemContentTypeTree == \"\($0)\"" }.joined(separator: " || ") + ")")
        }
        if !extensions.isEmpty {
            clauses.append("(" + extensions.sorted().map {
                "kMDItemFSName == \"*.\(Self.spotlightEscape($0, keepWildcards: false))\"c"
            }.joined(separator: " || ") + ")")
        }
        return clauses.isEmpty ? nil : clauses.joined(separator: " && ")
    }

    private static let contentTypes: [FileKind: String] = [
        .folder: "public.folder", .image: "public.image", .video: "public.movie", .audio: "public.audio",
        .pdf: "com.adobe.pdf", .archive: "public.archive", .code: "public.source-code", .text: "public.text",
        .app: "com.apple.application-bundle", .font: "public.font",
    ]

    private static func spotlightEscape(_ text: String, keepWildcards: Bool) -> String {
        var result = ""
        var escaped = false
        for character in text {
            if keepWildcards && escaped {
                escaped = false
                result += "\\\(character)"
                continue
            }
            if keepWildcards && character == "\\" {
                escaped = true
                continue
            }
            switch character {
            case "\"", "\\": result += "\\\(character)"
            case "*" where !keepWildcards: result += "\\*"
            default: result.append(character)
            }
        }
        return result
    }
}

enum SearchService {
    /// Searches `root` using the Spotlight index (fast, deep, and content-aware) merged with a
    /// bounded breadth-first walk that also finds hidden and unindexed items. Nothing is held in
    /// memory between searches — the index is the system's, so the app's footprint doesn't grow.
    static func search(
        root: String,
        query text: String,
        showHidden: Bool,
        limit: Int = 250,
        useIndex: Bool = true,
        partial: (@Sendable (SearchResponse) -> Void)? = nil
    ) -> SearchResponse {
        let start = URL(fileURLWithPath: root).standardizedFileURL.path
        let query = SearchQuery.parse(text)
        guard !query.isEmpty else { return SearchResponse(root: start, entries: [], truncated: false) }

        var found: [String: FileEntry] = [:]
        var truncated = false
        var indexed = false

        if useIndex, let spotlight = query.spotlightQuery() {
            let result = spotlightPaths(query: spotlight, root: start, cap: limit * 4)
            indexed = result.ran
            for path in result.paths where !Task.isCancelled {
                guard acceptIndexed(path, root: start, showHidden: showHidden),
                      let entry = FileService.entry(name: PathTools.basename(path), path: path),
                      query.matchesName(entry.name), query.matchesAttributes(entry) else { continue }
                found[path] = entry
            }
            if result.paths.count >= limit * 4 { truncated = true }
            if !found.isEmpty, let partial {
                partial(rank(found, query: query, root: start, limit: limit, truncated: true, indexed: true))
            }
        }
        guard !Task.isCancelled else { return SearchResponse(root: start, entries: [], truncated: true) }

        // With index results in hand, the walk only needs to fill in what Spotlight skips.
        let walk = walkSearch(
            root: start, query: query, showHidden: showHidden, limit: limit,
            deadline: indexed && !found.isEmpty ? 3 : 6
        )
        for entry in walk.entries where found[entry.path] == nil { found[entry.path] = entry }
        truncated = truncated || walk.truncated
        return rank(found, query: query, root: start, limit: limit, truncated: truncated, indexed: indexed)
    }

    private static func rank(
        _ found: [String: FileEntry],
        query: SearchQuery,
        root: String,
        limit: Int,
        truncated: Bool,
        indexed: Bool
    ) -> SearchResponse {
        let ranked = found.values
            .map { (entry: $0, score: query.relevance($0.name), depth: $0.path.split(separator: "/").count) }
            .sorted {
                if $0.score != $1.score { return $0.score < $1.score }
                if $0.depth != $1.depth { return $0.depth < $1.depth }
                return $0.entry.path < $1.entry.path
            }
        let entries = ranked.prefix(limit).map(\.entry)
        var response = SearchResponse(root: root, entries: Array(entries), truncated: truncated || ranked.count > limit)
        response.usedIndex = indexed
        return response
    }

    /// Mirrors the walk's rules for Spotlight hits: hidden folders, package contents, skipped
    /// system paths, and nested tool folders (`node_modules`, `.git`, …) are left out.
    private static func acceptIndexed(_ path: String, root: String, showHidden: Bool) -> Bool {
        guard path.hasPrefix(root == "/" ? "/" : root + "/"), !FileKinds.isSkippedSystemPath(path) else { return false }
        let relative = path.dropFirst(root == "/" ? 1 : root.count + 1)
        let components = relative.split(separator: "/")
        for (index, component) in components.enumerated() {
            let name = String(component)
            if !showHidden && name.hasPrefix(".") { return false }
            if index < components.count - 1 {
                if FileKinds.isPackageDirectory(name) { return false }
                if index > 0 && FileKinds.searchSkip.contains(name) { return false }
            }
        }
        // Skipped system paths can also be ancestors of the hit.
        var ancestor = PathTools.dirname(path)
        while ancestor.count > root.count {
            if FileKinds.isSkippedSystemPath(ancestor) { return false }
            ancestor = PathTools.dirname(ancestor)
        }
        return true
    }

    private static func spotlightPaths(query: String, root: String, cap: Int) -> (paths: [String], ran: Bool) {
        guard let mdQuery = MDQueryCreate(kCFAllocatorDefault, query as CFString, nil, nil) else { return ([], false) }
        MDQuerySetSearchScope(mdQuery, [root] as CFArray, 0)
        MDQuerySetMaxCount(mdQuery, cap)
        guard MDQueryExecute(mdQuery, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return ([], false) }
        defer { MDQueryStop(mdQuery) }
        let count = MDQueryGetResultCount(mdQuery)
        var paths: [String] = []
        paths.reserveCapacity(min(count, cap))
        let pathKey = "kMDItemPath" as CFString
        for index in 0..<count {
            guard let raw = MDQueryGetResultAtIndex(mdQuery, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            if let path = MDItemCopyAttribute(item, pathKey) as? String { paths.append(path) }
        }
        return (paths, true)
    }

    // MARK: Walk

    static func walkSearch(
        root start: String,
        query: SearchQuery,
        showHidden: Bool,
        limit: Int,
        deadline seconds: TimeInterval = 6
    ) -> (entries: [FileEntry], truncated: Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        // Breadth-first so shallow matches are found before the result limit is hit.
        var queue: [(path: String, depth: Int)] = [(start, 0)]
        var head = 0
        var results: [FileEntry] = []
        var truncated = false

        scan: while head < queue.count, results.count < limit {
            if Task.isCancelled || Date() > deadline {
                truncated = true
                break
            }
            let current = queue[head]
            head += 1
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: current.path) else { continue }
            for (offset, name) in names.enumerated() {
                if offset & 63 == 63, Task.isCancelled || Date() > deadline {
                    truncated = true
                    break scan
                }
                if !showHidden && name.hasPrefix(".") { continue }
                let fullPath = (current.path as NSString).appendingPathComponent(name)
                guard let link = FileService.statInfo(fullPath, followSymlinks: false) else { continue }
                if query.matchesName(name) {
                    let entry = FileService.makeEntry(name: name, path: fullPath, link: link)
                    if query.matchesAttributes(entry), contentMatches(entry, query: query) {
                        results.append(entry)
                        if results.count >= limit {
                            truncated = true
                            break scan
                        }
                    }
                }
                // lstat: symlinked directories report isDirectory == false and are not followed.
                if link.isDirectory,
                   current.depth < 10,
                   !shouldSkipDirectory(name, path: fullPath, showHidden: showHidden, isRoot: current.depth == 0) {
                    queue.append((fullPath, current.depth + 1))
                }
            }
        }
        if head < queue.count { truncated = true }
        return (results, truncated)
    }

    /// Content search fallback for unindexed locations: small text and code files only.
    private static func contentMatches(_ entry: FileEntry, query: SearchQuery) -> Bool {
        guard !query.content.isEmpty else { return true }
        guard !entry.isDirectory, entry.kind == .text || entry.kind == .code, entry.size <= 4_000_000 else { return false }
        return autoreleasepool {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: entry.path), options: .alwaysMapped),
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                return false
            }
            return query.content.allSatisfy {
                text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    private static func shouldSkipDirectory(_ name: String, path: String, showHidden: Bool, isRoot: Bool) -> Bool {
        if FileKinds.isPackageDirectory(name) { return true }
        if FileKinds.isSkippedSystemPath(path) { return true }
        if isRoot { return false }
        if !showHidden && name.hasPrefix(".") { return true }
        return FileKinds.searchSkip.contains(name)
    }
}
