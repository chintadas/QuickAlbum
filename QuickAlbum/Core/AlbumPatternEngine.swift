import Foundation

public struct PatternValidationResult: Equatable, Sendable {
    public let isValid: Bool
    public let errorMessage: String?
    public let previewPlain: String?
    public let previewWithLabel: String?

    public init(
        isValid: Bool,
        errorMessage: String?,
        previewPlain: String?,
        previewWithLabel: String?
    ) {
        self.isValid = isValid
        self.errorMessage = errorMessage
        self.previewPlain = previewPlain
        self.previewWithLabel = previewWithLabel
    }
}

public struct NextAlbumCandidate: Equatable, Sendable {
    public let title: String
    public let datePrefix: String
    public let counter: Int
    public let priorHighWaterMark: Int
    public let highWaterKey: String

    public init(
        title: String,
        datePrefix: String,
        counter: Int,
        priorHighWaterMark: Int,
        highWaterKey: String
    ) {
        self.title = title
        self.datePrefix = datePrefix
        self.counter = counter
        self.priorHighWaterMark = priorHighWaterMark
        self.highWaterKey = highWaterKey
    }
}

public enum AlbumPatternEngine {
    private enum Token: Equatable, Sendable {
        case year4
        case year2
        case month
        case day
        case counter(width: Int)
        case literal(String)
    }

    private struct CompiledTemplate {
        let tokens: [Token]
        let regex: NSRegularExpression?
        let year4Group: Int?
        let year2Group: Int?
        let monthGroup: Int?
        let dayGroup: Int?
        let counterGroup: Int?
        let labelGroup: Int?
        let validationError: String?
        let counterWidth: Int
    }

    // MARK: - Tokenization & Compilation

    private static func tokenize(_ template: String) -> (tokens: [Token], strayTokenError: String?) {
        var tokens: [Token] = []
        var literalBuffer = ""
        let chars = Array(template)
        var i = 0

        func flushLiteral() {
            if !literalBuffer.isEmpty {
                tokens.append(.literal(literalBuffer))
                literalBuffer = ""
            }
        }

        while i < chars.count {
            let remaining = String(chars[i...])
            if remaining.hasPrefix("YYYY") {
                flushLiteral()
                tokens.append(.year4)
                i += 4
            } else if remaining.hasPrefix("YY") {
                if remaining.hasPrefix("YYY") {
                    return ([], "Use YY or YYYY for year tokens.")
                }
                flushLiteral()
                tokens.append(.year2)
                i += 2
            } else if remaining.hasPrefix("MM") {
                if remaining.hasPrefix("MMM") {
                    return ([], "Use MM for 2-digit month.")
                }
                flushLiteral()
                tokens.append(.month)
                i += 2
            } else if remaining.hasPrefix("DD") {
                if remaining.hasPrefix("DDD") {
                    return ([], "Use DD for 2-digit day.")
                }
                flushLiteral()
                tokens.append(.day)
                i += 2
            } else if chars[i] == "x" {
                var count = 0
                while i + count < chars.count && chars[i + count] == "x" {
                    count += 1
                }
                if count < 2 {
                    return ([], "Counter token must be at least two digits (e.g., xx).")
                }
                flushLiteral()
                tokens.append(.counter(width: count))
                i += count
            } else {
                let ch = chars[i]
                if ch == "Y" || ch == "M" || ch == "D" || ch == "X" {
                    return ([], "Invalid token near '\(ch)'. Use YYYY, YY, MM, DD, and xx.")
                }
                literalBuffer.append(ch)
                i += 1
            }
        }
        flushLiteral()
        return (tokens, nil)
    }

    private static func compile(_ pattern: AlbumPattern) -> CompiledTemplate {
        let trimmed = pattern.template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return CompiledTemplate(
                tokens: [],
                regex: nil,
                year4Group: nil,
                year2Group: nil,
                monthGroup: nil,
                dayGroup: nil,
                counterGroup: nil,
                labelGroup: nil,
                validationError: "Template cannot be empty.",
                counterWidth: 2
            )
        }

        let (tokens, strayError) = tokenize(trimmed)
        if let strayError {
            return CompiledTemplate(
                tokens: [],
                regex: nil,
                year4Group: nil,
                year2Group: nil,
                monthGroup: nil,
                dayGroup: nil,
                counterGroup: nil,
                labelGroup: nil,
                validationError: strayError,
                counterWidth: 2
            )
        }

        var counterCount = 0
        var counterWidth = 2
        var hasDateToken = false

        for token in tokens {
            switch token {
            case .counter(let width):
                counterCount += 1
                counterWidth = width
            case .year4, .year2, .month, .day:
                hasDateToken = true
            case .literal:
                break
            }
        }

        if counterCount == 0 {
            return CompiledTemplate(
                tokens: tokens,
                regex: nil,
                year4Group: nil,
                year2Group: nil,
                monthGroup: nil,
                dayGroup: nil,
                counterGroup: nil,
                labelGroup: nil,
                validationError: "Template must include a counter token like xx.",
                counterWidth: 2
            )
        }
        if counterCount > 1 {
            return CompiledTemplate(
                tokens: tokens,
                regex: nil,
                year4Group: nil,
                year2Group: nil,
                monthGroup: nil,
                dayGroup: nil,
                counterGroup: nil,
                labelGroup: nil,
                validationError: "Template can only include one counter token.",
                counterWidth: counterWidth
            )
        }
        if !hasDateToken {
            return CompiledTemplate(
                tokens: tokens,
                regex: nil,
                year4Group: nil,
                year2Group: nil,
                monthGroup: nil,
                dayGroup: nil,
                counterGroup: nil,
                labelGroup: nil,
                validationError: "Template must include at least one date token (YY, YYYY, MM, or DD).",
                counterWidth: counterWidth
            )
        }

        var regexString = "^"
        var groupIndex = 0
        var year4Group: Int?
        var year2Group: Int?
        var monthGroup: Int?
        var dayGroup: Int?
        var counterGroup: Int?

        for token in tokens {
            switch token {
            case .year4:
                groupIndex += 1
                year4Group = groupIndex
                regexString += "(\\d{4})"
            case .year2:
                groupIndex += 1
                year2Group = groupIndex
                regexString += "(\\d{2})"
            case .month:
                groupIndex += 1
                monthGroup = groupIndex
                regexString += "(\\d{2})"
            case .day:
                groupIndex += 1
                dayGroup = groupIndex
                regexString += "(\\d{2})"
            case .counter(let width):
                groupIndex += 1
                counterGroup = groupIndex
                regexString += "(\\d{\(width),})"
            case .literal(let text):
                regexString += NSRegularExpression.escapedPattern(for: text)
            }
        }

        groupIndex += 1
        let labelGroup = groupIndex
        regexString += "(?:\\s+(\\S.*))?$"

        let regex = try? NSRegularExpression(pattern: regexString)
        return CompiledTemplate(
            tokens: tokens,
            regex: regex,
            year4Group: year4Group,
            year2Group: year2Group,
            monthGroup: monthGroup,
            dayGroup: dayGroup,
            counterGroup: counterGroup,
            labelGroup: labelGroup,
            validationError: regex == nil ? "Invalid template pattern." : nil,
            counterWidth: counterWidth
        )
    }

    // MARK: - Public API

    public static func validate(
        template: String,
        sampleDate: Date = Date(timeIntervalSince1970: 1_795_348_800), // 2026-11-22 12:00:00 UTC
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> PatternValidationResult {
        let pattern = AlbumPattern(template: template)
        let compiled = compile(pattern)
        if let error = compiled.validationError {
            return PatternValidationResult(
                isValid: false,
                errorMessage: error,
                previewPlain: nil,
                previewWithLabel: nil
            )
        }

        let plain = formatTitle(date: sampleDate, counter: 1, label: nil, pattern: pattern, calendar: calendar)
        let withLabel = formatTitle(date: sampleDate, counter: 1, label: "Beach", pattern: pattern, calendar: calendar)
        return PatternValidationResult(
            isValid: true,
            errorMessage: nil,
            previewPlain: plain,
            previewWithLabel: withLabel
        )
    }

    public static func parse(title: String, pattern: AlbumPattern) -> ParsedAlbumTitle? {
        let compiled = compile(pattern)
        guard compiled.validationError == nil, let regex = compiled.regex else {
            return nil
        }

        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        guard let match = regex.firstMatch(in: title, options: [], range: range) else {
            return nil
        }

        func captureInt(_ index: Int?) -> Int? {
            guard let index,
                  let swiftRange = Range(match.range(at: index), in: title) else {
                return nil
            }
            return Int(title[swiftRange])
        }

        func captureString(_ index: Int?) -> String? {
            guard let index,
                  let swiftRange = Range(match.range(at: index), in: title) else {
                return nil
            }
            return String(title[swiftRange])
        }

        guard let counter = captureInt(compiled.counterGroup) else {
            return nil
        }

        let year4 = captureInt(compiled.year4Group)
        let year2 = captureInt(compiled.year2Group)
        let normalizedYear = year4 ?? year2.map { 2000 + $0 }
        let month = captureInt(compiled.monthGroup)
        let day = captureInt(compiled.dayGroup)

        if let month, !(1...12).contains(month) {
            return nil
        }
        if let day, !(1...31).contains(day) {
            return nil
        }

        let datePrefix = renderPrefixFromCaptures(
            tokens: compiled.tokens,
            year4: captureString(compiled.year4Group),
            year2: captureString(compiled.year2Group),
            month: captureString(compiled.monthGroup),
            day: captureString(compiled.dayGroup)
        )

        let rawLabel = captureString(compiled.labelGroup)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = (rawLabel?.isEmpty == false) ? rawLabel : nil

        return ParsedAlbumTitle(
            datePrefix: datePrefix,
            counter: counter,
            label: label,
            year: normalizedYear,
            month: month,
            day: day
        )
    }

    public static func earliestDate(from dates: [Date?], fallback: Date = Date()) -> Date {
        dates.compactMap { $0 }.min() ?? fallback
    }

    public static func renderDatePrefix(
        for date: Date,
        pattern: AlbumPattern,
        calendar: Calendar = .current
    ) -> String {
        let compiled = compile(pattern)
        guard compiled.validationError == nil else {
            return renderDatePrefix(for: date, pattern: .default, calendar: calendar)
        }
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        let y = comps.year ?? 2026
        let m = comps.month ?? 1
        let d = comps.day ?? 1

        return renderPrefixFromCaptures(
            tokens: compiled.tokens,
            year4: String(format: "%04d", y),
            year2: String(format: "%02d", y % 100),
            month: String(format: "%02d", m),
            day: String(format: "%02d", d)
        )
    }

    public static func formatTitle(
        date: Date,
        counter: Int,
        label: String? = nil,
        pattern: AlbumPattern,
        calendar: Calendar = .current
    ) -> String {
        let compiled = compile(pattern)
        let effectiveTokens: [Token]
        let effectiveWidth: Int
        if compiled.validationError == nil {
            effectiveTokens = compiled.tokens
            effectiveWidth = compiled.counterWidth
        } else {
            let fallbackCompiled = compile(.default)
            effectiveTokens = fallbackCompiled.tokens
            effectiveWidth = fallbackCompiled.counterWidth
        }

        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        let y = comps.year ?? 2026
        let m = comps.month ?? 1
        let d = comps.day ?? 1

        var base = ""
        for token in effectiveTokens {
            switch token {
            case .year4:
                base += String(format: "%04d", y)
            case .year2:
                base += String(format: "%02d", y % 100)
            case .month:
                base += String(format: "%02d", m)
            case .day:
                base += String(format: "%02d", d)
            case .counter(let width):
                base += formatCounter(counter, width: max(width, effectiveWidth))
            case .literal(let text):
                base += text
            }
        }

        if let trimmedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmedLabel.isEmpty {
            return "\(base) \(trimmedLabel)"
        }
        return base
    }

    public static func replacingLabel(
        in parsed: ParsedAlbumTitle,
        with newLabel: String?,
        pattern: AlbumPattern
    ) -> String {
        let compiled = compile(pattern)
        let effectiveTokens = compiled.validationError == nil ? compiled.tokens : compile(.default).tokens

        let year4Str = parsed.year.map { String(format: "%04d", $0) }
        let year2Str = parsed.year.map { String(format: "%02d", $0 % 100) }
        let monthStr = parsed.month.map { String(format: "%02d", $0) }
        let dayStr = parsed.day.map { String(format: "%02d", $0) }

        var base = ""
        for token in effectiveTokens {
            switch token {
            case .year4:
                base += year4Str ?? "0000"
            case .year2:
                base += year2Str ?? "00"
            case .month:
                base += monthStr ?? "01"
            case .day:
                base += dayStr ?? "01"
            case .counter(let width):
                base += formatCounter(parsed.counter, width: width)
            case .literal(let text):
                base += text
            }
        }

        if let trimmedLabel = newLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmedLabel.isEmpty {
            return "\(base) \(trimmedLabel)"
        }
        return base
    }

    public static func highWaterKey(pattern: AlbumPattern, datePrefix: String) -> String {
        "\(pattern.template)|\(datePrefix)"
    }

    public static func computeNextAlbum(
        for date: Date,
        existingAlbums: [AlbumSummary],
        pattern: AlbumPattern,
        counterStore: CounterHistoryStoring,
        calendar: Calendar = .current
    ) -> NextAlbumCandidate {
        let datePrefix = renderDatePrefix(for: date, pattern: pattern, calendar: calendar)
        let key = highWaterKey(pattern: pattern, datePrefix: datePrefix)

        let existingMax = existingAlbums
            .compactMap(\.parsed)
            .filter { $0.datePrefix == datePrefix }
            .map(\.counter)
            .max() ?? 0

        let storedHigh = counterStore.highWaterMark(for: key)
        let priorHigh = max(existingMax, storedHigh)
        let nextCounter = priorHigh + 1
        let title = formatTitle(
            date: date,
            counter: nextCounter,
            label: nil,
            pattern: pattern,
            calendar: calendar
        )

        return NextAlbumCandidate(
            title: title,
            datePrefix: datePrefix,
            counter: nextCounter,
            priorHighWaterMark: priorHigh,
            highWaterKey: key
        )
    }

    public static func commitCounter(key: String, counter: Int, store: CounterHistoryStoring) {
        let existing = store.highWaterMark(for: key)
        if counter > existing {
            store.setHighWaterMark(counter, for: key)
        }
    }

    public static func rollbackCounter(key: String, previousHighWaterMark: Int, store: CounterHistoryStoring) {
        store.setHighWaterMark(previousHighWaterMark, for: key)
    }

    // MARK: - Helpers

    private static func formatCounter(_ counter: Int, width: Int) -> String {
        let raw = String(counter)
        if raw.count >= width {
            return raw
        }
        return String(repeating: "0", count: width - raw.count) + raw
    }

    private static func renderPrefixFromCaptures(
        tokens: [Token],
        year4: String?,
        year2: String?,
        month: String?,
        day: String?
    ) -> String {
        // Strip the delimiter token immediately adjacent to `.counter`
        // (preceding `.counter` if present, otherwise following `.counter` when at index 0).
        var counterIdx: Int?
        for (idx, token) in tokens.enumerated() {
            if case .counter = token {
                counterIdx = idx
                break
            }
        }

        var skipLiteralIndex: Int?
        if let cIdx = counterIdx {
            if cIdx > 0, case .literal = tokens[cIdx - 1] {
                skipLiteralIndex = cIdx - 1
            } else if cIdx + 1 < tokens.count, case .literal = tokens[cIdx + 1] {
                skipLiteralIndex = cIdx + 1
            }
        }

        var result = ""
        for (idx, token) in tokens.enumerated() {
            if idx == skipLiteralIndex {
                continue
            }
            switch token {
            case .year4:
                result += year4 ?? ""
            case .year2:
                result += year2 ?? ""
            case .month:
                result += month ?? ""
            case .day:
                result += day ?? ""
            case .counter:
                break
            case .literal(let text):
                result += text
            }
        }
        return result
    }
}
