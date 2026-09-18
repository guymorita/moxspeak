import Foundation

/// Expands language a phonemizer cannot read aloud: numbers, money, times, dates,
/// abbreviations, units.
///
/// Deliberately NOT part of `TextPreparer`. The two do different jobs at different times.
/// `TextPreparer` strips *document formatting* — markdown, PDF hard wraps, emoji — and
/// always runs, because that noise is never speech no matter which engine is downstream.
/// This type expands *language*, and whether that is wanted depends entirely on the engine:
/// a server-side normalizer (Kokoro-FastAPI) already does it, and doing it twice corrupts
/// the text — "$5" becomes "five dollars" becomes "five dollars dollars". So this runs only
/// when `SpeechProvider.requiresTextNormalization` asks for it.
///
/// Every rule here was measured against the reference phonemizer (Python `misaki`) rather
/// than guessed at: the target is that normalized text phonemizes to the same thing the
/// reference produces from the raw text, so that dropping the Python server changes nothing
/// a listener can hear. Where the rules below deliberately diverge from the reference, it is
/// because the reference is audibly wrong (it reads "3:30" with the colon still in it), and
/// each of those is called out at the rule.
///
/// Order matters and is not arbitrary — see `normalize`.
public struct TextNormalizer: Sendable {

    public struct Options: Sendable {
        /// "Dr." -> "Doctor". Off leaves the period, which also invites a bogus sentence split.
        public var expandAbbreviations: Bool = true
        /// "state-of-the-art" -> "state of the art".
        ///
        /// Not cosmetic. Kokoro's phonemizer maps a bare hyphen to "—", which is token id 9
        /// in the vocab: a real spoken pause. A hyphenated compound would be read with a
        /// silence in the middle of the word.
        public var splitHyphenatedCompounds: Bool = true
        /// "10KB" -> "ten kilobytes". Limited to units with no plausible second reading.
        public var expandUnits: Bool = true
        public init() {}
    }

    private let options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    /// Stages run in a fixed order, and most of the order is load-bearing:
    ///
    /// - URLs and emails go first, before anything else gets a chance to pick apart the dots,
    ///   colons, slashes and digits inside one — a bare "3.14" rule would happily eat the
    ///   "3.14" out of a path, and the abbreviation rule would see "St." inside a hostname.
    /// - Abbreviations go next so "Dec. 3rd" is a month before anything looks at the 3.
    /// - Currency precedes plain numbers so "$1,234.56" is one amount, not a number and a
    ///   stray decimal.
    /// - Phone numbers and dates precede ranges, because both contain a digit-hyphen-digit
    ///   that would otherwise be read as "to".
    /// - Ranges precede the general number rules, which would turn the digits into words and
    ///   leave the hyphen behind as a pause.
    /// - Units precede the number rules so "2000Hz" is a frequency rather than a year.
    /// - Hyphen splitting goes last, after every rule that wanted to see a hyphen — including
    ///   this one, so a hyphenated host label ("my-site.com" -> "my site dot com") reads the
    ///   same way any other hyphenated compound does.
    public func normalize(_ text: String) -> String {
        var out = expandURLsAndEmails(text)

        if options.expandAbbreviations {
            out = expandAbbreviations(out)
        }
        out = expandCurrency(out)
        out = expandPercentages(out)
        out = expandPhoneNumbers(out)
        out = expandDates(out)
        out = expandRanges(out)
        out = expandTimes(out)
        out = expandVersionStrings(out)
        if options.expandUnits {
            out = expandUnits(out)
        }
        out = expandDecades(out)
        out = expandOrdinals(out)
        out = expandNumbers(out)
        if options.splitHyphenatedCompounds {
            out = splitHyphens(out)
        }

        return collapseWhitespace(out)
    }

    // MARK: - URLs and emails

    /// What a person actually says reading a URL aloud: the host, and nothing else. Nobody
    /// speaks a protocol ("h t t p s colon slash slash"), and a path or query string is
    /// essentially never worth hearing — "nytimes.com/2026/09/18/tech" is "nytimes dot com"
    /// with the date-shaped path silently dropped, not read digit by digit. Saying less here
    /// is the deliberate choice: a path read aloud is noise nobody wants, where a dropped path
    /// costs nothing a listener would have used. "www." is dropped for the same reason as the
    /// protocol — nobody says it — but the rest of the host is kept and spoken as
    /// dot-separated words, because the host is the one part of a URL that carries meaning.
    ///
    /// A bare domain with no scheme and no "www." ("example.com" sitting in a sentence) is
    /// only recognized against a fixed list of common TLDs. Every other rule in this type can
    /// use a shape (a `$`, a `:`, a four-digit run) that is unambiguous on its own; "word.word"
    /// is not — it is also how a sentence ends before a capitalized abbreviation, or an
    /// abbreviation like "Mr." or "e.g." sits before the next word. The TLD whitelist is what
    /// keeps those from being mistaken for a domain. `https://` and `www.` URLs carry their
    /// own unambiguous signal and need no such whitelist.
    ///
    /// Runs before every other stage — see `normalize` — so a URL's dots, colons, digits and
    /// slashes are read out as a whole here rather than being picked apart piecemeal by the
    /// currency, time, version-string and number rules downstream.
    ///
    /// The bare-domain TLD list is kept short and unambiguous on purpose — it stands in for a
    /// judgment call, and a missed rare TLD is a far cheaper mistake than a wrongly claimed
    /// sentence boundary.
    private func expandURLsAndEmails(_ text: String) -> String {
        var out = text

        // guy@example.com -> "guy at example dot com". Ahead of the URL rules below: an
        // email's domain looks exactly like a bare domain, and the "www." rule would have no
        // opinion about it while still leaving the "@" behind for the phonemizer to spell out.
        out = out.replacing(/\b([A-Za-z0-9._%+-]+)@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)\b/) { match in
            let local = String(match.1).replacing(".", with: " dot ")
            let domain = String(match.2).split(separator: ".").map(String.init).joined(separator: " dot ")
            return "\(local) at \(domain)"
        }

        // https://example.com/docs, http://www.example.com -> "example dot com". The scheme
        // is never spoken; whatever follows the host (path, query, fragment, port) is dropped.
        out = out.replacing(/\bhttps?:\/\/(\S+)/) { match in
            Self.spokenHost(String(match.1))
        }

        // www.example.com/docs -> "example dot com" — same reasoning, no scheme this time.
        out = out.replacing(/\bwww\.(\S+)/) { match in
            Self.spokenHost("www." + String(match.1))
        }

        // A bare domain with no scheme and no "www.": only recognized against a known TLD, so
        // an ordinary sentence boundary or abbreviation is never mistaken for one.
        out = out.replacing(
            /\b([A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*\.(?:com|org|net|edu|gov|mil|io|co|ai|app|dev|info|biz|me|tv|us|uk))\b(\/\S*)?/
        ) { match in
            let domain = String(match.1).split(separator: ".").map(String.init).joined(separator: " dot ")
            guard let path = match.2 else { return domain }
            return domain + Self.trailingPunctuation(String(path))
        }

        return out
    }

    /// What follows a `https://` scheme or a `www.` prefix: an optional (already-included)
    /// "www.", then a host, then whatever comes after it. Strips the "www.", cuts at the first
    /// path/query/fragment/port delimiter, and reads what remains as dot-separated words —
    /// while salvaging any sentence punctuation glued directly onto the end, which otherwise
    /// belongs to the sentence and not the URL and must not be silently dropped along with it.
    private static func spokenHost(_ rest: String) -> String {
        var body = rest
        if body.lowercased().hasPrefix("www.") {
            body = String(body.dropFirst(4))
        }
        let trailing = trailingPunctuation(body)
        if !trailing.isEmpty {
            body.removeLast(trailing.count)
        }
        if let cut = body.firstIndex(where: { "/?#:".contains($0) }) {
            body = String(body[body.startIndex..<cut])
        }
        let labels = body.split(separator: ".").map(String.init)
        guard !labels.isEmpty else { return rest }
        return labels.joined(separator: " dot ") + trailing
    }

    /// The run of sentence punctuation glued onto the very end of a string, if any —
    /// "example.com." at a sentence's end, "example.com," mid-list, "(example.com)" in an
    /// aside. A URL never legitimately ends in one of these itself, so whatever trails is the
    /// surrounding sentence's, and must be read back out rather than vanish with a dropped path.
    private static func trailingPunctuation(_ text: String) -> String {
        var trailing = ""
        for char in text.reversed() {
            guard ".,;:!?)]}\"'".contains(char) else { break }
            trailing = String(char) + trailing
        }
        return trailing
    }

    // MARK: - Abbreviations

    /// An expansion plus the two things that cannot be read off the expansion itself.
    ///
    /// `requiresCapital` is how "Mar." the month is told apart from a sentence that happened
    /// to end on the word "mar" — the capital is the only signal there is. It is off for the
    /// handful of abbreviations normally written lowercase ("etc.", "vs.", "approx."), which
    /// therefore have no such signal and are taken on the spelling alone.
    ///
    /// `mayEndSentence` exists because the period is the real difficulty here. For most
    /// abbreviations it is pure noise that additionally fools the segmenter into starting a
    /// new sentence, so it goes. But "etc." and "Inc." routinely finish a sentence, and
    /// dropping the period there welds two sentences together. Flagging them is only half the
    /// answer: "Acme Corp. reported" must still lose its period, or the sentence splits in
    /// the middle. So the flag makes the period *conditional*, and the rule below decides
    /// from what actually follows.
    private struct Abbreviation {
        let expansion: String
        let requiresCapital: Bool
        let mayEndSentence: Bool
        init(_ expansion: String, requiresCapital: Bool = true, mayEndSentence: Bool = false) {
            self.expansion = expansion
            self.requiresCapital = requiresCapital
            self.mayEndSentence = mayEndSentence
        }
    }

    private static let abbreviations: [String: Abbreviation] = [
        // Titles.
        "dr": Abbreviation("Doctor"),
        "mr": Abbreviation("Mister"),
        "mrs": Abbreviation("Missus"),
        // "Miz", not "Miss": they are different honorifics, and "Miz" is the respelling that
        // the reference lexicon phonemizes identically to "Ms."
        "ms": Abbreviation("Miz"),
        "prof": Abbreviation("Professor"),
        "rev": Abbreviation("Reverend"),
        "hon": Abbreviation("Honorable"),
        "sgt": Abbreviation("Sergeant"),
        "capt": Abbreviation("Captain"),
        "lt": Abbreviation("Lieutenant"),
        "gen": Abbreviation("General"),
        "jr": Abbreviation("Junior", mayEndSentence: true),
        "sr": Abbreviation("Senior", mayEndSentence: true),
        // Months.
        "jan": Abbreviation("January"),
        "feb": Abbreviation("February"),
        "mar": Abbreviation("March"),
        "apr": Abbreviation("April"),
        "jun": Abbreviation("June"),
        "jul": Abbreviation("July"),
        "aug": Abbreviation("August"),
        "sep": Abbreviation("September"),
        "sept": Abbreviation("September"),
        "oct": Abbreviation("October"),
        "nov": Abbreviation("November"),
        "dec": Abbreviation("December"),
        // Weekdays.
        "mon": Abbreviation("Monday"),
        "tue": Abbreviation("Tuesday"),
        "tues": Abbreviation("Tuesday"),
        "wed": Abbreviation("Wednesday"),
        "thu": Abbreviation("Thursday"),
        "thur": Abbreviation("Thursday"),
        "thurs": Abbreviation("Thursday"),
        "fri": Abbreviation("Friday"),
        "sat": Abbreviation("Saturday"),
        "sun": Abbreviation("Sunday"),
        // Places.
        "ave": Abbreviation("Avenue"),
        "blvd": Abbreviation("Boulevard"),
        "rd": Abbreviation("Road"),
        "ln": Abbreviation("Lane"),
        "mt": Abbreviation("Mount"),
        "ft": Abbreviation("Fort"),
        // Organizations — these end sentences often enough to keep the period.
        "inc": Abbreviation("Incorporated", mayEndSentence: true),
        "ltd": Abbreviation("Limited", mayEndSentence: true),
        "corp": Abbreviation("Corporation", mayEndSentence: true),
        "co": Abbreviation("Company", mayEndSentence: true),
        // Prose.
        "etc": Abbreviation("etcetera", requiresCapital: false, mayEndSentence: true),
        "vs": Abbreviation("versus", requiresCapital: false),
        "approx": Abbreviation("approximately", requiresCapital: false),
    ]

    private func expandAbbreviations(_ text: String) -> String {
        var out = text

        // Multi-period forms first: the single-token rule below would see "e" and "g" as two
        // separate abbreviations and never recognize the pair.
        out = out.replacing(/\be\.\s?g\./, with: "for example")
        out = out.replacing(/\bi\.\s?e\./, with: "that is")
        out = out.replacing(/\ba\.m\./, with: "AM")
        out = out.replacing(/\bp\.m\./, with: "PM")

        // "St." is two different words and only context separates them. A following capital
        // is a name ("St. Andrews"), anything else is a thoroughfare ("Elm St.").
        out = out.replacing(/\bSt\.(\s+)(?=[A-Z])/) { match in "Saint\(match.1)" }
        out = out.replacing(/\bSt\./, with: "Street")

        // The trailing run is captured, not looked ahead at, because the decision about the
        // period depends on it: an abbreviation that can end a sentence keeps its period only
        // when a sentence plausibly ends there — nothing follows, or what follows is
        // capitalized. "Acme Corp. reported" loses it; "Acme Corp. Reported earnings." keeps
        // it. Whatever was captured is put back verbatim.
        out = out.replacing(/\b([A-Za-z]{2,6})\.(?![\w.])([ \t]*)([A-Za-z"'(]?)/) { match in
            let token = String(match.1)
            guard let abbreviation = Self.abbreviations[token.lowercased()] else {
                return String(match.0)
            }
            if abbreviation.requiresCapital && token.first?.isUppercase != true {
                return String(match.0)
            }
            let following = String(match.3)
            let endsSentence = following.isEmpty || following.first?.isUppercase == true
                || following.first == "\"" || following.first == "'" || following.first == "("
            let period = abbreviation.mayEndSentence && endsSentence ? "." : ""
            // A capital on the source token is carried to the expansion. Capitalization is
            // not decoration to the phonemizer: it reads a leading capital as a proper noun
            // and an all-caps word as an initialism, and each gets its own stress.
            let expansion = token.first?.isUppercase == true
                ? abbreviation.expansion.withCapitalizedFirst
                : abbreviation.expansion
            return expansion + period + String(match.2) + following
        }

        return out
    }

    // MARK: - Currency

    private struct Currency {
        let unit: String
        let subunit: String
        /// "pence" is already plural; "cents" is not.
        let subunitHasPlural: Bool
    }

    private static let currencies: [String: Currency] = [
        "$": Currency(unit: "dollar", subunit: "cent", subunitHasPlural: true),
        "£": Currency(unit: "pound", subunit: "pence", subunitHasPlural: false),
        "€": Currency(unit: "euro", subunit: "cent", subunitHasPlural: true),
    ]

    private static let magnitudes: [String: String] = [
        "K": "thousand", "M": "million", "B": "billion", "T": "trillion",
    ]

    private func expandCurrency(_ text: String) -> String {
        var out = text

        // "$5M" — magnitude suffix. Matched first, because the plain rule below would take
        // the "5" and abandon the "M" to be spelled out as a letter.
        out = out.replacing(/([$£€])\s?(-?)(\d[\d,]*(?:\.\d+)?)([KMBT])\b/) { match in
            guard let currency = Self.currencies[String(match.1)] else { return String(match.0) }
            let magnitude = Self.magnitudes[String(match.4)] ?? ""
            let amount = Self.spokenNumber(String(match.3))
            let sign = match.2 == "-" ? "minus " : ""
            return "\(sign)\(amount) \(magnitude) \(currency.unit)s"
        }

        out = out.replacing(/([$£€])\s?(-?)(\d[\d,]*(?:\.\d+)?)/) { match in
            guard let currency = Self.currencies[String(match.1)] else { return String(match.0) }
            let sign = match.2 == "-" ? "minus " : ""
            return sign + Self.spokenAmount(String(match.3), in: currency)
        }

        return out
    }

    /// "1,234.56" in dollars -> "one thousand two hundred thirty four dollars and fifty six
    /// cents".
    ///
    /// A whole amount drops the subunit entirely, and an amount under one unit drops the unit
    /// — "$0.50" is "fifty cents", not "zero dollars and fifty cents". A fraction longer than
    /// two digits is not money at all (a rate, usually), so it falls back to a plain decimal.
    private static func spokenAmount(_ digits: String, in currency: Currency) -> String {
        let parts = digits.replacing(",", with: "").split(separator: ".", omittingEmptySubsequences: false)
        let wholePart = String(parts.first ?? "")
        let whole = Int(wholePart) ?? 0

        guard parts.count > 1 else {
            return NumberWords.integer(wholePart) + " " + pluralized(currency.unit, whole)
        }

        let rawFraction = String(parts[1])
        guard rawFraction.count <= 2 else {
            let amount = NumberWords.decimal(integerPart: wholePart, fractionPart: rawFraction)
            return amount + " " + currency.unit + "s"
        }

        // "$1.5" is a dollar fifty. The digits after the point are a position, not a count.
        let fractionDigits = rawFraction.count == 1 ? rawFraction + "0" : rawFraction
        let fraction = Int(fractionDigits) ?? 0

        let subunitWord = currency.subunitHasPlural
            ? pluralized(currency.subunit, fraction)
            : currency.subunit

        if fraction == 0 {
            return NumberWords.integer(wholePart) + " " + pluralized(currency.unit, whole)
        }
        if whole == 0 {
            return NumberWords.cardinal(fraction) + " " + subunitWord
        }
        return NumberWords.integer(wholePart) + " " + pluralized(currency.unit, whole)
            + " and " + NumberWords.cardinal(fraction) + " " + subunitWord
    }

    private static func pluralized(_ unit: String, _ count: Int) -> String {
        abs(count) == 1 ? unit : unit + "s"
    }

    /// A number that may carry a grouping separator or a decimal point, as words.
    private static func spokenNumber(_ digits: String) -> String {
        let stripped = digits.replacing(",", with: "")
        guard let dot = stripped.firstIndex(of: ".") else {
            return NumberWords.integer(stripped)
        }
        return NumberWords.decimal(integerPart: String(stripped[stripped.startIndex..<dot]),
                                   fractionPart: String(stripped[stripped.index(after: dot)...]))
    }

    // MARK: - Percentages

    private func expandPercentages(_ text: String) -> String {
        text.replacing(/(-?)(\d[\d,]*(?:\.\d+)?)\s?%/) { match in
            let sign = match.1 == "-" ? "minus " : ""
            return sign + Self.spokenNumber(String(match.2)) + " percent"
        }
    }

    // MARK: - Phone numbers

    /// Read digit by digit. A phone number is an identifier, not a quantity, and the hyphens
    /// in it would otherwise be heard as pauses or as "to".
    private func expandPhoneNumbers(_ text: String) -> String {
        var out = text
        out = out.replacing(/\b(\d{3})-(\d{3})-(\d{4})\b/) { match in
            [match.1, match.2, match.3].map(NumberWords.spelledDigits).joined(separator: " ")
        }
        out = out.replacing(/\b(\d{3})-(\d{4})\b/) { match in
            [match.1, match.2].map(NumberWords.spelledDigits).joined(separator: " ")
        }
        return out
    }

    // MARK: - Dates

    private func expandDates(_ text: String) -> String {
        var out = text

        // ISO: 2024-01-15.
        out = out.replacing(/\b(\d{4})-(\d{1,2})-(\d{1,2})\b/) { match in
            guard let year = Int(match.1), let month = Int(match.2), let day = Int(match.3),
                  (1...12).contains(month), (1...31).contains(day)
            else { return String(match.0) }
            return "\(NumberWords.monthNames[month - 1]) \(NumberWords.ordinal(day)) \(NumberWords.year(year))"
        }

        // US slash: 7/4/1776, 07/04/76.
        out = out.replacing(/\b(\d{1,2})\/(\d{1,2})\/(\d{2,4})\b/) { match in
            guard let month = Int(match.1), let day = Int(match.2), let year = Int(match.3),
                  (1...12).contains(month), (1...31).contains(day)
            else { return String(match.0) }
            return "\(NumberWords.monthNames[month - 1]) \(NumberWords.ordinal(day)) \(NumberWords.year(year))"
        }

        // "July 4" -> "July fourth". "July 4th" is left alone here; the ordinal rule has it,
        // and `\b` cannot match between the 4 and the th so this pattern never sees it.
        //
        // The lookahead is what keeps "May 5 people attended" from becoming "May fifth
        // people". A bare number after a month name is only a date when the phrase ends
        // there, a year follows, or the next word is one that can join a date to a sentence.
        // Anything else is a count that happens to sit next to a month.
        out = out.replacing(/\b(January|February|March|April|May|June|July|August|September|October|November|December)\s+(\d{1,2})\b(?=\s*(?:[,.;:!?)]|$)|\s+(?:of|at|in|by|for|from|through|until|on)\b|\s+\d{4}\b)/) { match in
            guard let day = Int(match.2), (1...31).contains(day) else { return String(match.0) }
            return "\(match.1) \(NumberWords.ordinal(day))"
        }

        return out
    }

    // MARK: - Ranges

    /// "5-10" -> "five to ten". Runs after phone numbers and dates, which own their hyphens.
    private func expandRanges(_ text: String) -> String {
        text.replacing(/(\d)-(?=\d)/) { match in "\(match.1) to " }
    }

    // MARK: - Times

    /// "3:30" -> "three thirty", "3:00" -> "three o'clock", "12:05" -> "twelve oh five",
    /// "5:45pm" -> "five forty five p m", "9am" -> "nine a m",
    /// "2:04:36" -> "two hours four minutes thirty six seconds".
    ///
    /// A deliberate divergence from the reference, which leaves the colon in place and
    /// phonemizes "3:30" as "three : thirty" with an audible break. There is no reading of
    /// a clock time in which that is right.
    ///
    /// `h:mm` (with an optional am/pm) is read as a clock time. `h:mm:ss` and `hh:mm:ss` are
    /// read as a duration instead — three colon-separated fields is the shape of a stopwatch
    /// or a running time ("the video is 2:04:36 long"), not of anything anyone reads aloud as
    /// a moment in the day, so that is the reading picked when only the field count is known.
    /// A three-field run with an am/pm suffix attached is rare enough, and ambiguous enough,
    /// that it is left untouched rather than guessed at.
    private func expandTimes(_ text: String) -> String {
        var out = text

        // The whole colon-separated run is matched, not just the first two fields, so a
        // three-field stopwatch reading is told apart from a clock time rather than having
        // its first two fields misread as one. An am/pm suffix — spaced, glued, dotted, or
        // not — is captured with it so it lands in the same replacement as the time itself.
        out = out.replacing(/\b(\d{1,2})((?::\d{1,2})+)(?:[ \t]?([AaPp]\.?[Mm]\.?))?\b/) { match in
            let fields = match.2.split(separator: ":").map(String.init)
            let meridiem = match.3.map(String.init)

            if fields.count == 1 {
                guard let hour = Int(match.1), let minute = Int(fields[0]), fields[0].count == 2,
                      (0...59).contains(minute),
                      meridiem == nil ? (0...23).contains(hour) : (1...12).contains(hour)
                else { return String(match.0) }
                return Self.spokenTime(hour: hour, minute: minute, meridiem: meridiem)
            }

            if fields.count == 2, meridiem == nil {
                guard let hour = Int(match.1), let minute = Int(fields[0]), let second = Int(fields[1]),
                      fields[0].count == 2, fields[1].count == 2,
                      (0...59).contains(minute), (0...59).contains(second)
                else { return String(match.0) }
                return Self.spokenDuration(hours: hour, minutes: minute, seconds: second)
            }

            return String(match.0)
        }

        // A bare hour with no colon at all — "9am", "9 AM", "9 p.m." — never reached the rule
        // above, which requires at least one colon field.
        out = out.replacing(/\b(\d{1,2})[ \t]?([AaPp]\.?[Mm]\.?)\b/) { match in
            guard let hour = Int(match.1), (1...12).contains(hour) else { return String(match.0) }
            return Self.spokenTime(hour: hour, minute: 0, meridiem: String(match.2))
        }

        return out
    }

    private static func spokenTime(hour: Int, minute: Int, meridiem: String? = nil) -> String {
        let hourWords = NumberWords.cardinal(hour)
        let meridiemWords = meridiem.map(spokenMeridiem)
        if minute == 0 {
            guard let meridiemWords else { return hourWords + " o'clock" }
            return hourWords + " " + meridiemWords
        }
        let minuteWords = minute < 10 ? "oh " + NumberWords.ones[minute] : NumberWords.cardinal(minute)
        let core = hourWords + " " + minuteWords
        guard let meridiemWords else { return core }
        return core + " " + meridiemWords
    }

    /// "am", "AM", "a.m.", "A.M." all read the same way: the two letters, spoken.
    private static func spokenMeridiem(_ raw: String) -> String {
        raw.first?.lowercased() == "a" ? "a m" : "p m"
    }

    /// "2:04:36" -> "two hours four minutes thirty six seconds". A zero-valued field is
    /// dropped rather than spoken, matching how this is said aloud ("two hours and thirty
    /// six seconds", not "two hours zero minutes thirty six seconds").
    private static func spokenDuration(hours: Int, minutes: Int, seconds: Int) -> String {
        var parts: [String] = []
        if hours > 0 { parts.append(NumberWords.cardinal(hours) + " " + unit("hour", hours)) }
        if minutes > 0 { parts.append(NumberWords.cardinal(minutes) + " " + unit("minute", minutes)) }
        if seconds > 0 { parts.append(NumberWords.cardinal(seconds) + " " + unit("second", seconds)) }
        return parts.isEmpty ? "zero seconds" : parts.joined(separator: " ")
    }

    private static func unit(_ word: String, _ count: Int) -> String {
        count == 1 ? word : word + "s"
    }

    // MARK: - Version strings

    /// "3.1.4" -> "three point one point four". Two or more dots, so it can never be confused
    /// with a decimal. The reference drops the dots entirely and says "three one four".
    private func expandVersionStrings(_ text: String) -> String {
        text.replacing(/\b(\d+(?:\.\d+){2,})\b/) { match in
            match.1.split(separator: ".")
                .map { NumberWords.integer(String($0)) }
                .joined(separator: " point ")
        }
    }

    // MARK: - Units

    private struct Unit {
        let singular: String
        let plural: String
        init(_ singular: String, _ plural: String? = nil) {
            self.singular = singular
            self.plural = plural ?? singular + "s"
        }
    }

    /// Only units with no plausible second reading. "m" (metres or million), "in" (inches or
    /// the preposition) and "s" (seconds or a plural) are all deliberately absent: guessing
    /// wrong on those is worse than leaving the letter to the phonemizer.
    private static let units: [String: Unit] = [
        "KB": Unit("kilobyte"), "MB": Unit("megabyte"), "GB": Unit("gigabyte"),
        "TB": Unit("terabyte"), "PB": Unit("petabyte"),
        "kb": Unit("kilobyte"), "mb": Unit("megabyte"), "gb": Unit("gigabyte"),
        "tb": Unit("terabyte"),
        "km": Unit("kilometer"), "cm": Unit("centimeter"), "mm": Unit("millimeter"),
        "nm": Unit("nanometer"), "kg": Unit("kilogram"), "mg": Unit("milligram"),
        "ms": Unit("millisecond"), "ns": Unit("nanosecond"),
        "Hz": Unit("hertz", "hertz"), "kHz": Unit("kilohertz", "kilohertz"),
        "MHz": Unit("megahertz", "megahertz"), "GHz": Unit("gigahertz", "gigahertz"),
        "mph": Unit("miles per hour", "miles per hour"),
        "kph": Unit("kilometers per hour", "kilometers per hour"),
        "lb": Unit("pound"), "lbs": Unit("pound"), "oz": Unit("ounce"),
        "ft": Unit("foot", "feet"),
    ]

    private func expandUnits(_ text: String) -> String {
        // Longest alternatives first so "kHz" is not read as "k" plus "Hz", and "lbs" is not
        // read as "lb" plus a stray "s".
        text.replacing(/\b(\d[\d,]*(?:\.\d+)?)[ \u{00A0}]?(kHz|MHz|GHz|Hz|KB|MB|GB|TB|PB|kb|mb|gb|tb|mph|kph|lbs|km|cm|mm|nm|kg|mg|ms|ns|lb|oz|ft)\b/) { match in
            guard let unit = Self.units[String(match.2)] else { return String(match.0) }
            let digits = String(match.1)
            let isOne = digits.replacing(",", with: "") == "1"
            return Self.spokenNumber(digits) + " " + (isOne ? unit.singular : unit.plural)
        }
    }

    // MARK: - Decades

    /// "1980s" -> "nineteen eighties".
    private func expandDecades(_ text: String) -> String {
        text.replacing(/\b(\d{4})s\b/) { match in
            guard let year = Int(match.1) else { return String(match.0) }
            return NumberWords.decade(year)
        }
    }

    // MARK: - Ordinals

    private func expandOrdinals(_ text: String) -> String {
        text.replacing(/\b(\d[\d,]*)(st|nd|rd|th|ST|ND|RD|TH)\b/) { match in
            let digits = String(match.1.replacing(",", with: ""))
            guard digits.count <= NumberWords.maximumSpellableDigits, let value = Int(digits)
            else { return String(match.0) }
            return NumberWords.ordinal(value)
        }
    }

    // MARK: - Numbers

    private func expandNumbers(_ text: String) -> String {
        var out = text

        // A hyphen is a minus only where a number could start: after whitespace, an opening
        // bracket, or at the very beginning. Between two digits it is a range, and that rule
        // has already run.
        out = out.replacing(/(^|[\s(\[])-(?=\d)/) { match in "\(match.1)minus " }

        // Either a properly grouped number or a bare digit run, with an optional fraction.
        out = out.replacing(/\b(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d+))?\b/) { match in
            let digits = String(match.1.replacing(",", with: ""))
            if let fraction = match.2 {
                return NumberWords.decimal(integerPart: digits, fractionPart: String(fraction))
            }
            // A bare four-digit run is a year. This is the reference's rule, not an invention,
            // and it is why "In 2024" reads "twenty twenty four" rather than "two thousand
            // twenty four". A grouped "1,234" keeps its separator through to here and so is
            // read as a quantity, which is the intended escape hatch.
            if match.1.count == 4 && !match.1.contains(",") && !digits.hasPrefix("0"),
               let value = Int(digits) {
                return NumberWords.year(value)
            }
            return NumberWords.integer(digits)
        }

        return out
    }

    // MARK: - Hyphens

    /// The lookahead is the point: it consumes the character *before* the hyphen but not the
    /// one after, so "state-of-the-art" is fixed in a single pass. Consuming both would make
    /// the next hyphen unreachable and leave every other one in place.
    private func splitHyphens(_ text: String) -> String {
        text.replacing(/([A-Za-z0-9])-(?=[A-Za-z])/) { match in "\(match.1) " }
    }

    // MARK: - Whitespace

    private func collapseWhitespace(_ text: String) -> String {
        text.replacing(/[ \t\u{00A0}]+/, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    /// "approximately" -> "Approximately". Only the first character, unlike `capitalized`,
    /// which also lowercases the rest and would turn "AM" into "Am".
    var withCapitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
