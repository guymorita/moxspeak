import Foundation

/// Integers and digit strings as spoken English words.
///
/// Hand-written rather than `NumberFormatter(.spellOut)`, which was measured against the
/// reference phonemizer and rejected on three counts: it hyphenates ("twenty-five"), which
/// is exactly the character this whole exercise exists to keep away from the phonemizer; it
/// inserts "and" ("one hundred and one"), which the reference drops; and it has no notion of
/// a year, so 2024 comes out "two thousand twenty-four" instead of "twenty twenty-four".
/// It is also locale-sensitive and allocates a formatter per call. This is a few tables and
/// a switch, and it runs in the latency path.
enum NumberWords {

    // MARK: - Tables

    static let ones = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
        "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
        "seventeen", "eighteen", "nineteen",
    ]

    private static let tens = [
        "", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
    ]

    /// Descending so the first match is the largest applicable scale.
    private static let scales: [(value: Int, name: String)] = [
        (1_000_000_000_000, "trillion"),
        (1_000_000_000, "billion"),
        (1_000_000, "million"),
        (1_000, "thousand"),
    ]

    private static let ordinalForms: [String: String] = [
        "zero": "zeroth", "one": "first", "two": "second", "three": "third",
        "four": "fourth", "five": "fifth", "six": "sixth", "seven": "seventh",
        "eight": "eighth", "nine": "ninth", "ten": "tenth", "eleven": "eleventh",
        "twelve": "twelfth", "twenty": "twentieth", "thirty": "thirtieth",
        "forty": "fortieth", "fifty": "fiftieth", "sixty": "sixtieth",
        "seventy": "seventieth", "eighty": "eightieth", "ninety": "ninetieth",
        "hundred": "hundredth", "thousand": "thousandth", "million": "millionth",
        "billion": "billionth", "trillion": "trillionth",
    ]

    /// Decade plurals: "eighty" -> "eighties", "ten" -> "tens".
    private static let decadePlurals: [String: String] = [
        "twenty": "twenties", "thirty": "thirties", "forty": "forties",
        "fifty": "fifties", "sixty": "sixties", "seventy": "seventies",
        "eighty": "eighties", "ninety": "nineties", "hundred": "hundreds",
        "thousand": "thousands",
    ]

    static let monthNames = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]

    /// Beyond this many digits an `Int` conversion is not worth risking, and nobody wants
    /// to hear "nine hundred quintillion" anyway — such a run is read digit by digit.
    static let maximumSpellableDigits = 15

    // MARK: - Cardinals

    static func cardinal(_ n: Int) -> String {
        if n < 0 { return "minus " + cardinal(-n) }
        if n < 20 { return ones[n] }
        if n < 100 {
            let tensWord = tens[n / 10]
            return n % 10 == 0 ? tensWord : tensWord + " " + ones[n % 10]
        }
        if n < 1000 {
            let hundreds = ones[n / 100] + " hundred"
            return n % 100 == 0 ? hundreds : hundreds + " " + cardinal(n % 100)
        }
        for scale in scales where n >= scale.value {
            let head = cardinal(n / scale.value) + " " + scale.name
            let remainder = n % scale.value
            return remainder == 0 ? head : head + " " + cardinal(remainder)
        }
        return ones[0]
    }

    // MARK: - Years

    /// 2024 -> "twenty twenty four", 1805 -> "eighteen oh five", 1900 -> "nineteen hundred".
    ///
    /// Three cases fall back to the plain cardinal, matching the reference: a value under
    /// 100, a round century-decade with a single-digit tail (2005 is "two thousand five",
    /// not "twenty oh five"), and anything past 9999.
    static func year(_ n: Int) -> String {
        guard n >= 0 else { return cardinal(n) }
        let high = n / 100
        let low = n % 100
        if high == 0 || (high % 10 == 0 && low < 10) || high >= 100 {
            return cardinal(n)
        }
        let highWords = cardinal(high)
        let lowWords: String
        if low == 0 {
            lowWords = "hundred"
        } else if low < 10 {
            lowWords = "oh " + ones[low]
        } else {
            lowWords = cardinal(low)
        }
        return highWords + " " + lowWords
    }

    /// 1980 -> "nineteen eighties". Falls back to `year` + "s" for shapes with no plural.
    static func decade(_ n: Int) -> String {
        let words = year(n).split(separator: " ").map(String.init)
        guard let last = words.last else { return "" }
        let plural = decadePlurals[last] ?? (last + "s")
        return (words.dropLast() + [plural]).joined(separator: " ")
    }

    // MARK: - Ordinals

    /// 22 -> "twenty second", 101 -> "one hundred first", 1000 -> "one thousandth".
    static func ordinal(_ n: Int) -> String {
        var words = cardinal(n).split(separator: " ").map(String.init)
        guard let last = words.popLast() else { return "" }
        words.append(ordinalForms[last] ?? (last + "th"))
        return words.joined(separator: " ")
    }

    // MARK: - Digit runs

    /// "0142" -> "zero one four two". Non-digits are dropped.
    static func spelledDigits(_ digits: some StringProtocol) -> String {
        digits.compactMap { character -> String? in
            guard let value = character.wholeNumberValue, (0...9).contains(value) else {
                return nil
            }
            return ones[value]
        }.joined(separator: " ")
    }

    /// A run of digits with separators already stripped, spoken as a quantity.
    ///
    /// A leading zero means the run is an identifier rather than a quantity ("0142" is a
    /// phone tail, not one hundred forty two), so it is read digit by digit. So is anything
    /// too long to convert safely.
    static func integer(_ digits: String) -> String {
        guard !digits.isEmpty else { return "" }
        if digits.count > 1 && digits.hasPrefix("0") { return spelledDigits(digits) }
        guard digits.count <= maximumSpellableDigits, let value = Int(digits) else {
            return spelledDigits(digits)
        }
        return cardinal(value)
    }

    // MARK: - Decimals

    /// "3", "14" -> "three point one four". A fraction of only zeros is dropped entirely,
    /// matching the reference ("3.0" is "three", not "three point zero").
    static func decimal(integerPart: String, fractionPart: String) -> String {
        let fraction = trimmedFraction(fractionPart)
        let head = integerPart.isEmpty ? "" : integer(integerPart)
        if fraction.isEmpty { return head.isEmpty ? "zero" : head }
        let tail = "point " + spelledDigits(fraction)
        return head.isEmpty ? tail : head + " " + tail
    }

    /// Trailing zeros carry no sound: "0.50" is "point five".
    private static func trimmedFraction(_ fraction: String) -> String {
        var trimmed = Substring(fraction)
        while trimmed.last == "0" { trimmed = trimmed.dropLast() }
        return String(trimmed)
    }
}
