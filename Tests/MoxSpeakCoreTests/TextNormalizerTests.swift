import Testing
import Foundation
@testable import MoxSpeakCore

private let n = TextNormalizer()

// MARK: - Cardinals

@Test func expandsSmallAndRoundCardinals() {
    #expect(n.normalize("We counted 7 birds.") == "We counted seven birds.")
    #expect(n.normalize("There were 12 people.") == "There were twelve people.")
    #expect(n.normalize("It has 47 floors.") == "It has forty seven floors.")
    #expect(n.normalize("She ran 100 laps.") == "She ran one hundred laps.")
    #expect(n.normalize("Roughly 999 entries.") == "Roughly nine hundred ninety nine entries.")
}

/// No "and" anywhere: the reference phonemizer drops it, and so must this.
@Test func cardinalsNeverInsertAnd() {
    #expect(n.normalize("He owes 101 dollars.") == "He owes one hundred one dollars.")
    #expect(n.normalize("The tally is 113 votes.") == "The tally is one hundred thirteen votes.")
}

@Test func expandsLargeCardinalsWithThousandsSeparators() {
    #expect(n.normalize("We processed 1,234 requests.")
            == "We processed one thousand two hundred thirty four requests.")
    #expect(n.normalize("It grew to 12,500 residents.")
            == "It grew to twelve thousand five hundred residents.")
    #expect(n.normalize("Target is 150,000 subscribers.")
            == "Target is one hundred fifty thousand subscribers.")
    #expect(n.normalize("It holds 3,400,000 shares.")
            == "It holds three million four hundred thousand shares.")
    #expect(n.normalize("About 2,750,000,000 particles.")
            == "About two billion seven hundred fifty million particles.")
    #expect(n.normalize("An error of 1,000,000,000,000 is implausible.")
            == "An error of one trillion is implausible.")
}

/// A grouped number is a quantity even at four digits, which is the escape hatch from the
/// year rule below.
@Test func groupedFourDigitNumberIsAQuantityNotAYear() {
    #expect(n.normalize("We logged 1,234 hits.") == "We logged one thousand two hundred thirty four hits.")
}

/// A leading zero means an identifier, not a quantity. The reference reads "0007" as "seven".
@Test func leadingZeroRunsAreReadDigitByDigit() {
    #expect(n.normalize("The code is 0142.") == "The code is zero one four two.")
    #expect(n.normalize("It ends in 0007.") == "It ends in zero zero zero seven.")
}

// MARK: - Decimals, negatives, versions

@Test func expandsDecimals() {
    #expect(n.normalize("The gauge read 3.14.") == "The gauge read three point one four.")
    #expect(n.normalize("Accuracy was 99.5.") == "Accuracy was ninety nine point five.")
    #expect(n.normalize("It dropped to 0.5.") == "It dropped to zero point five.")
    #expect(n.normalize("We measured 12.75.") == "We measured twelve point seven five.")
}

/// Trailing zeros are silent: the reference turns "3.0" into "three", not "three point zero".
@Test func decimalsDropTrailingZeros() {
    #expect(n.normalize("Version 2.0 shipped.") == "Version two shipped.")
    #expect(n.normalize("It was 0.50 exactly.") == "It was zero point five exactly.")
}

@Test func expandsNegativeNumbers() {
    #expect(n.normalize("The offset is -5 here.") == "The offset is minus five here.")
    #expect(n.normalize("It fell to -12 overnight.") == "It fell to minus twelve overnight.")
    #expect(n.normalize("The delta was -0.75 today.") == "The delta was minus zero point seven five today.")
}

/// The spike's exact failure: "3.1.4" vanished entirely from the Swift phonemizer's output.
@Test func expandsVersionStrings() {
    #expect(n.normalize("We shipped 3.1.4 last week.")
            == "We shipped three point one point four last week.")
    #expect(n.normalize("Upgrade to 10.15.7 first.")
            == "Upgrade to ten point fifteen point seven first.")
    #expect(n.normalize("See 1.2.3.4 for an example.")
            == "See one point two point three point four for an example.")
}

// MARK: - Currency

/// The spike's headline failure: "$1,234.56" phonemized as "minus six hundred ten point
/// four four zero five five nine nine nine…".
@Test func expandsDollarsWithSeparatorsAndCents() {
    #expect(n.normalize("The total came to $1,234.56 after tax.")
            == "The total came to one thousand two hundred thirty four dollars and fifty six cents after tax.")
}

@Test func currencyUsesSingularForExactlyOne() {
    #expect(n.normalize("It cost $1 flat.") == "It cost one dollar flat.")
    #expect(n.normalize("It cost $5 flat.") == "It cost five dollars flat.")
    #expect(n.normalize("The fine was £1 total.") == "The fine was one pound total.")
    #expect(n.normalize("The deposit is €1 each.") == "The deposit is one euro each.")
}

@Test func wholeCurrencyAmountsDropTheSubunit() {
    #expect(n.normalize("The invoice showed $42.00 today.") == "The invoice showed forty two dollars today.")
}

@Test func amountsUnderOneUnitDropTheUnit() {
    #expect(n.normalize("The bill was $0.99 exactly.") == "The bill was ninety nine cents exactly.")
}

/// A single digit after the point is a position, not a count: "$1.5" is a dollar fifty.
@Test func singleDigitCentsArePositional() {
    #expect(n.normalize("I paid $1.5 for it.") == "I paid one dollar and fifty cents for it.")
}

/// Pence is already plural and never takes an "s".
@Test func poundsUsePence() {
    #expect(n.normalize("The coffee cost £3.50 today.") == "The coffee cost three pounds and fifty pence today.")
    #expect(n.normalize("It sold for £35 there.") == "It sold for thirty five pounds there.")
}

@Test func expandsEuros() {
    #expect(n.normalize("The ticket was €40 total.") == "The ticket was forty euros total.")
    #expect(n.normalize("The refund was €12.30 back.") == "The refund was twelve euros and thirty cents back.")
}

@Test func expandsCurrencyMagnitudeSuffixes() {
    #expect(n.normalize("Revenue hit $5M this year.") == "Revenue hit five million dollars this year.")
    #expect(n.normalize("The round was $15,000,000 post.")
            == "The round was fifteen million dollars post.")
}

@Test func expandsNegativeCurrency() {
    #expect(n.normalize("The balance is $-5 now.") == "The balance is minus five dollars now.")
}

// MARK: - Percentages

/// The spike's failure: the percent sign was dropped entirely and "50%" became "fifty".
@Test func expandsPercentages() {
    #expect(n.normalize("Turnout rose 50% today.") == "Turnout rose fifty percent today.")
    #expect(n.normalize("Margins improved 2.5% here.") == "Margins improved two point five percent here.")
    #expect(n.normalize("The rate is 0.5% monthly.") == "The rate is zero point five percent monthly.")
}

// MARK: - Years

/// The spike's failure: "2024" phonemized as "twenty four", losing the century entirely.
@Test func expandsFourDigitYearsAsYears() {
    #expect(n.normalize("In 2024 it changed.") == "In twenty twenty four it changed.")
    #expect(n.normalize("Signed in 1776 finally.") == "Signed in seventeen seventy six finally.")
    #expect(n.normalize("Finished in 1066 exactly.") == "Finished in ten sixty six exactly.")
}

/// A round century says "hundred"; a round millennium and its single-digit tail fall back to
/// the cardinal. Both match the reference, which is the only reason to prefer them.
@Test func yearsHandleRoundCenturiesAndMillennia() {
    #expect(n.normalize("Records begin in 1900 here.") == "Records begin in nineteen hundred here.")
    #expect(n.normalize("Nothing from 2000 survives.") == "Nothing from two thousand survives.")
    #expect(n.normalize("It dates to 2005 exactly.") == "It dates to two thousand five exactly.")
}

@Test func yearsUseOhForSingleDigitTails() {
    #expect(n.normalize("The photo is from 1805 originally.")
            == "The photo is from eighteen oh five originally.")
    #expect(n.normalize("Dated 1010 by the archive.") == "Dated ten ten by the archive.")
}

@Test func expandsDecades() {
    #expect(n.normalize("It peaked in the 1980s.") == "It peaked in the nineteen eighties.")
    #expect(n.normalize("Fashion in the 1920s was loud.") == "Fashion in the nineteen twenties was loud.")
}

// MARK: - Dates

@Test func expandsIsoDates() {
    #expect(n.normalize("The meeting is on 2024-01-15 sharp.")
            == "The meeting is on January fifteenth twenty twenty four sharp.")
}

@Test func expandsSlashDates() {
    #expect(n.normalize("Her birthday is 7/4/1776 yearly.")
            == "Her birthday is July fourth seventeen seventy six yearly.")
    #expect(n.normalize("Dated 12/25/2023 by hand.")
            == "Dated December twenty fifth twenty twenty three by hand.")
}

@Test func expandsMonthAndDayAsAnOrdinal() {
    #expect(n.normalize("We close on January 15 of next year.")
            == "We close on January fifteenth of next year.")
    #expect(n.normalize("The hearing is set for March 3.")
            == "The hearing is set for March third.")
    #expect(n.normalize("The gala is June 12, 2027.") == "The gala is June twelfth, twenty twenty seven.")
}

/// A number after a month name is only a date when the phrase ends there or a date word
/// follows. Otherwise it is a count that happens to sit next to a month.
@Test func aCountAfterAMonthNameIsNotADay() {
    #expect(n.normalize("May 5 people attended.") == "May five people attended.")
    #expect(n.normalize("He read August 9 as a warning.") == "He read August nine as a warning.")
}

// MARK: - Times

@Test func expandsClockTimes() {
    #expect(n.normalize("The train leaves at 3:30 tomorrow.")
            == "The train leaves at three thirty tomorrow.")
    #expect(n.normalize("Boarding closes at 10:45 exactly.")
            == "Boarding closes at ten forty five exactly.")
    #expect(n.normalize("The eclipse peaks at 14:22 today.")
            == "The eclipse peaks at fourteen twenty two today.")
}

@Test func expandsTopOfTheHourAsOClock() {
    #expect(n.normalize("Doors open at 9:00 sharp.") == "Doors open at nine o'clock sharp.")
}

@Test func expandsSingleDigitMinutesWithOh() {
    #expect(n.normalize("The alarm rang at 12:05 then.") == "The alarm rang at twelve oh five then.")
}

/// Three colon-separated fields is a duration, not a clock time — matching "h:mm" alone
/// would find "23:45" inside "1:23:45" and read a stopwatch as a clock.
@Test func expandsHourMinuteSecondAsADuration() {
    #expect(n.normalize("The meeting ran 1:23:45 in total.")
            == "The meeting ran one hour twenty three minutes forty five seconds in total.")
}

/// The defect this was built to fix: the colons used to survive into the phoneme string.
@Test func expandsHourMinuteSecondDurationWithTwoDigitHour() {
    #expect(n.normalize("The episode runs 2:04:36 long.")
            == "The episode runs two hours four minutes thirty six seconds long.")
}

/// A duration field of zero is dropped rather than spoken.
@Test func durationDropsZeroValuedFields() {
    #expect(n.normalize("It finished in 1:00:09 flat.")
            == "It finished in one hour nine seconds flat.")
    #expect(n.normalize("The clip is 0:05:00 long.") == "The clip is five minutes long.")
}

// MARK: - Times with am/pm

/// The defect this was built to fix: "5:45pm" used to phonemize as the non-word "fivepeem"
/// because the glued "pm" was left for the phonemizer to guess at.
@Test func expandsClockTimeWithGluedMeridiem() {
    #expect(n.normalize("Doors open at 5:45pm sharp.") == "Doors open at five forty five p m sharp.")
}

@Test func expandsClockTimeWithSpacedMeridiem() {
    #expect(n.normalize("Doors open at 5:45 pm sharp.") == "Doors open at five forty five p m sharp.")
}

@Test func expandsClockTimeWithDottedMeridiem() {
    #expect(n.normalize("Doors open at 5:45 p.m. sharp.") == "Doors open at five forty five p m sharp.")
    #expect(n.normalize("Doors open at 5:45 P.M. sharp.") == "Doors open at five forty five p m sharp.")
}

/// The defect this was built to fix: a bare hour with no colon was not expanded at all.
@Test func expandsBareHourWithMeridiem() {
    #expect(n.normalize("We start at 9am sharp.") == "We start at nine a m sharp.")
    #expect(n.normalize("We start at 9 am sharp.") == "We start at nine a m sharp.")
    #expect(n.normalize("We start at 9AM sharp.") == "We start at nine a m sharp.")
    #expect(n.normalize("We start at 9Am sharp.") == "We start at nine a m sharp.")
}

@Test func topOfTheHourWithMeridiemOmitsOClock() {
    #expect(n.normalize("The gate closes at 9:00pm tonight.") == "The gate closes at nine p m tonight.")
}

/// Ratios and always-on phrases get no special time/duration reading — that part is
/// deliberately left unhandled, same as before this fix. The colon and slash themselves
/// survive; only the individual digit runs either side are spelled out by the general
/// number rule, exactly as they were pre-fix.
@Test func timeRulesLeaveRatiosAndUnrelatedColonsAlone() {
    #expect(n.normalize("The odds were 3:1 against.") == "The odds were three:one against.")
    #expect(n.normalize("Support runs 24/7 always.") == "Support runs twenty four/seven always.")
}

/// A bare "12:00" reads as a clock time, not a ratio.
@Test func bareTwelveOhOhReadsAsATime() {
    #expect(n.normalize("The kitchen closes at 12:00 sharp.") == "The kitchen closes at twelve o'clock sharp.")
}

// MARK: - Ordinals

@Test func expandsOrdinals() {
    #expect(n.normalize("She finished 1st overall.") == "She finished first overall.")
    #expect(n.normalize("He came in 2nd today.") == "He came in second today.")
    #expect(n.normalize("They placed 3rd there.") == "They placed third there.")
    #expect(n.normalize("The runner was 4th then.") == "The runner was fourth then.")
    #expect(n.normalize("She was 22nd on the board.") == "She was twenty second on the board.")
    #expect(n.normalize("His name was 101st on it.") == "His name was one hundred first on it.")
}

// MARK: - Abbreviations

@Test func expandsTitleAbbreviations() {
    #expect(n.normalize("Dr. Smith will see you now.") == "Doctor Smith will see you now.")
    #expect(n.normalize("Mr. and Mrs. Johnson arrived.") == "Mister and Missus Johnson arrived.")
    #expect(n.normalize("Ms. Delgado filed it.") == "Miz Delgado filed it.")
    #expect(n.normalize("Prof. Lindqvist spoke.") == "Professor Lindqvist spoke.")
}

/// The spike's failure: "Dec." phonemized as "decter".
@Test func expandsMonthAbbreviations() {
    #expect(n.normalize("The deadline is Wednesday, Dec. 3rd.")
            == "The deadline is Wednesday, December third.")
    #expect(n.normalize("It arrives in Dec. of this year.") == "It arrives in December of this year.")
}

/// "St." is two different words and only the following capital separates them.
@Test func disambiguatesSaintFromStreet() {
    #expect(n.normalize("Mr. and Mrs. Johnson live on St. Andrews Road.")
            == "Mister and Missus Johnson live on Saint Andrews Road.")
    #expect(n.normalize("The parade goes down Elm St. every year.")
            == "The parade goes down Elm Street every year.")
}

/// The period survives only where a sentence plausibly ends, which is not the same thing as
/// the abbreviation being one that can end a sentence.
@Test func abbreviationPeriodSurvivesOnlyAtASentenceEnd() {
    #expect(n.normalize("Bring pens, paper, folders, etc.") == "Bring pens, paper, folders, etcetera.")
    #expect(n.normalize("The firm is Acme Inc. They filed today.")
            == "The firm is Acme Incorporated. They filed today.")
    #expect(n.normalize("Acme Corp. reported earnings early.")
            == "Acme Corporation reported earnings early.")
}

@Test func expandsMultiPeriodAbbreviations() {
    #expect(n.normalize("Bring a gift, e.g. a plant.") == "Bring a gift, for example a plant.")
    #expect(n.normalize("The result, i.e. the median, held.")
            == "The result, that is the median, held.")
}

/// Capitalization is a signal to the phonemizer, not decoration, so it is carried across.
@Test func abbreviationExpansionKeepsTheSourceCapitalization() {
    #expect(n.normalize("Approx. 40 people attended.") == "Approximately forty people attended.")
    #expect(n.normalize("It was approx. 40 people.") == "It was approximately forty people.")
}

/// Lowercase is how a month abbreviation is told from a word that ended a sentence.
@Test func lowercaseWordsAreNotMistakenForAbbreviations() {
    #expect(n.normalize("He will mar. the surface.") == "He will mar. the surface.")
}

// MARK: - Hyphenated compounds

/// The reason this rule exists: the phonemizer maps a bare hyphen to "—", token id 9 in
/// Kokoro's vocab, which is a real spoken pause in the middle of the word.
@Test func splitsHyphenatedCompounds() {
    #expect(n.normalize("This is a state-of-the-art well-designed user-friendly device.")
            == "This is a state of the art well designed user friendly device.")
    #expect(n.normalize("Wi-Fi coverage is spotty.") == "Wi Fi coverage is spotty.")
    #expect(n.normalize("The twenty-five year old contract expired.")
            == "The twenty five year old contract expired.")
    #expect(n.normalize("It was a no-nonsense, high-stakes talk.")
            == "It was a no nonsense, high stakes talk.")
}

@Test func splitsHyphensBetweenLettersAndDigits() {
    #expect(n.normalize("COVID-19 changed everything.") == "COVID nineteen changed everything.")
}

@Test func leavesNoHyphenBehindInASpacedEmDashReplacement() {
    // TextPreparer turns an em dash into " - ", which is a deliberate pause and must survive.
    #expect(n.normalize("He paused - then spoke.") == "He paused - then spoke.")
}

// MARK: - Ranges and phone numbers

@Test func readsDigitRangesAsTo() {
    #expect(n.normalize("Attendance ranged 5-10 people.") == "Attendance ranged five to ten people.")
    #expect(n.normalize("Expect 20-30 minutes here.") == "Expect twenty to thirty minutes here.")
}

/// A phone number is an identifier, not a quantity: the reference reads "555-0142" as "five
/// hundred fifty five" followed by a glued "one forty two".
@Test func readsPhoneNumbersDigitByDigit() {
    #expect(n.normalize("Call me at 555-0142 or extension 7.")
            == "Call me at five five five zero one four two or extension seven.")
    #expect(n.normalize("Reach dispatch at 212-555-0199 anytime.")
            == "Reach dispatch at two one two five five five zero one nine nine anytime.")
}

// MARK: - Units

@Test func expandsByteUnits() {
    #expect(n.normalize("The file is 10KB on disk.") == "The file is ten kilobytes on disk.")
    #expect(n.normalize("It grew to 250MB overnight.") == "It grew to two hundred fifty megabytes overnight.")
    #expect(n.normalize("The drive holds 2TB total.") == "The drive holds two terabytes total.")
    #expect(n.normalize("It stalled at 1.5GB left.") == "It stalled at one point five gigabytes left.")
}

@Test func expandsMetricAndTimeUnits() {
    #expect(n.normalize("The trail is 5km out.") == "The trail is five kilometers out.")
    #expect(n.normalize("The gap measured 12mm across.") == "The gap measured twelve millimeters across.")
    #expect(n.normalize("It weighed 250mg exactly.") == "It weighed two hundred fifty milligrams exactly.")
    #expect(n.normalize("Latency held at 20ms flat.") == "Latency held at twenty milliseconds flat.")
}

/// Hertz is its own plural, and "mph" is a phrase rather than a noun.
@Test func unitsWithoutARegularPluralKeepTheirForm() {
    #expect(n.normalize("The display runs at 120Hz here.")
            == "The display runs at one hundred twenty hertz here.")
    #expect(n.normalize("The chip runs at 3GHz sustained.") == "The chip runs at three gigahertz sustained.")
    #expect(n.normalize("The limit is 65mph here.") == "The limit is sixty five miles per hour here.")
    #expect(n.normalize("The board is 8ft long.") == "The board is eight feet long.")
}

@Test func unitsAreSingularForExactlyOne() {
    #expect(n.normalize("The file is 1KB on disk.") == "The file is one kilobyte on disk.")
}

/// A unit beats the year rule, or "2000Hz" would be read as a date.
@Test func aUnitSuffixPreemptsTheYearRule() {
    #expect(n.normalize("The tone is 2000Hz steady.") == "The tone is two thousand hertz steady.")
}

/// Units whose expansion would be a guess are deliberately absent.
@Test func ambiguousUnitsAreLeftAlone() {
    #expect(n.normalize("The board is 8 in wide.") == "The board is eight in wide.")
    #expect(n.normalize("It ran 5 m ahead.") == "It ran five m ahead.")
}

// MARK: - Things that must not change

@Test func leavesAlphanumericIdentifiersAlone() {
    #expect(n.normalize("An MP3 file and an A4 sheet.") == "An MP3 file and an A4 sheet.")
    #expect(n.normalize("The 3D printer is here.") == "The 3D printer is here.")
    #expect(n.normalize("Wi-Fi needs a WPA2 passphrase.") == "Wi Fi needs a WPA2 passphrase.")
}

@Test func normalizerLeavesPlainProseUntouched() {
    let prose = "The quick brown fox jumps over the lazy dog."
    #expect(n.normalize(prose) == prose)
    let contractions = "I can't believe they're already done, it's incredible."
    #expect(n.normalize(contractions) == contractions)
}

// MARK: - Options

@Test func abbreviationExpansionCanBeTurnedOff() {
    var opts = TextNormalizer.Options()
    opts.expandAbbreviations = false
    #expect(TextNormalizer(options: opts).normalize("Dr. Smith is here.") == "Dr. Smith is here.")
}

@Test func hyphenSplittingCanBeTurnedOff() {
    var opts = TextNormalizer.Options()
    opts.splitHyphenatedCompounds = false
    #expect(TextNormalizer(options: opts).normalize("A state-of-the-art device.")
            == "A state-of-the-art device.")
}

/// With units off the digits are left alone too, not expanded and stranded next to a bare
/// "KB": there is no word boundary between "10" and "KB", so the number rule never sees it.
@Test func unitExpansionCanBeTurnedOff() {
    var opts = TextNormalizer.Options()
    opts.expandUnits = false
    #expect(TextNormalizer(options: opts).normalize("The file is 10KB here.")
            == "The file is 10KB here.")
}

// MARK: - URLs

/// What a person actually says reading a URL aloud: the host, nothing else. The scheme is
/// never spoken and the path is dropped entirely.
@Test func expandsFullURLsToTheHostOnly() {
    #expect(n.normalize("Read the docs at https://example.com/docs for setup.")
            == "Read the docs at example dot com for setup.")
    #expect(n.normalize("The API lives at http://example.com/v1/users today.")
            == "The API lives at example dot com today.")
}

/// A query string is exactly the kind of thing nobody wants read aloud.
@Test func dropsQueryStringsFromURLs() {
    #expect(n.normalize("Search at https://example.com/search?q=hello&lang=en today.")
            == "Search at example dot com today.")
}

/// "www." is dropped along with the scheme — nobody says it out loud either — but the rest
/// of the host, and only the host, survives.
@Test func expandsWWWPrefixedURLsToTheHostOnly() {
    #expect(n.normalize("It ran in www.nytimes.com/2026/09/18/tech yesterday.")
            == "It ran in nytimes dot com yesterday.")
    #expect(n.normalize("Sales info is at www.example.com today.")
            == "Sales info is at example dot com today.")
}

/// A bare domain with no scheme and no "www." still reads as a domain, not as a sentence
/// that happens to end in "com".
@Test func expandsBareDomainsWithNoSchemeOrWWW() {
    #expect(n.normalize("Full coverage is at example.com now.") == "Full coverage is at example dot com now.")
    #expect(n.normalize("The archive is at docs.example.org now.")
            == "The archive is at docs dot example dot org now.")
}

/// A bare domain can carry a path too, and it is dropped the same as a scheme'd one.
@Test func dropsThePathFromABareDomain() {
    #expect(n.normalize("It ran in nytimes.com/2026/09/18/tech yesterday.")
            == "It ran in nytimes dot com yesterday.")
}

/// A multi-level TLD like "co.uk" is still read as dot-separated words in full.
@Test func expandsMultiLevelTLDs() {
    #expect(n.normalize("Order it from example.co.uk today.") == "Order it from example dot co dot uk today.")
}

/// A URL mid-sentence keeps the punctuation that was never part of it — dropping the path
/// must not eat the comma or period that belongs to the surrounding sentence.
@Test func urlInsideASentenceKeepsSurroundingPunctuation() {
    #expect(n.normalize("Check out https://example.com/docs, it's great.")
            == "Check out example dot com, it's great.")
}

/// The defect this exists to avoid: dropping the path must not also drop the sentence's own
/// final period and weld two sentences together.
@Test func urlAtASentenceEndKeepsTheSentencePeriod() {
    #expect(n.normalize("Read more at https://example.com/docs. It covers setup.")
            == "Read more at example dot com. It covers setup.")
    #expect(n.normalize("Read more at example.com. It covers setup.")
            == "Read more at example dot com. It covers setup.")
}

// MARK: - Emails

@Test func expandsEmailAddresses() {
    #expect(n.normalize("Reach out to guy@example.com for access.")
            == "Reach out to guy at example dot com for access.")
}

/// A dotted local part is spoken the same way a person reads it aloud.
@Test func expandsEmailAddressesWithADottedLocalPart() {
    #expect(n.normalize("Email first.last@example.com about it.")
            == "Email first dot last at example dot com about it.")
}

@Test func emailAtASentenceEndKeepsTheSentencePeriod() {
    #expect(n.normalize("Send it to guy@example.com. Then wait.")
            == "Send it to guy at example dot com. Then wait.")
}

// MARK: - URLs and emails must not regress existing dot/colon rules

/// "co" is itself a recognized TLD; a "Co." abbreviation sitting after a space must not be
/// swept up by the domain rule, which requires the TLD to be glued directly onto a label.
@Test func coAbbreviationIsNotMistakenForADomain() {
    #expect(n.normalize("Acme Co. reported earnings early.") == "Acme Company reported earnings early.")
}

/// Version strings, decimals, times, and multi-period abbreviations all contain dots or
/// colons that must still be read the old way, not swallowed as a URL.
@Test func urlRulesDoNotRegressExistingDotAndColonHandling() {
    #expect(n.normalize("We shipped 3.1.4 last week.") == "We shipped three point one point four last week.")
    #expect(n.normalize("The gauge read 3.14.") == "The gauge read three point one four.")
    #expect(n.normalize("The train leaves at 3:30 tomorrow.")
            == "The train leaves at three thirty tomorrow.")
    #expect(n.normalize("Bring a gift, e.g. a plant.") == "Bring a gift, for example a plant.")
    #expect(n.normalize("The total came to $1,234.56 after tax.")
            == "The total came to one thousand two hundred thirty four dollars and fifty six cents after tax.")
}

// MARK: - Idempotence

/// Normalizing twice must be the same as normalizing once. Not a curiosity: the failure this
/// guards is exactly the one that makes the rule engine-dependent — "$5" becoming "five
/// dollars" and then "five dollars dollars".
@Test func normalizationIsIdempotent() {
    let inputs = [
        "The total came to $1,234.56 after tax.",
        "In 2024 we shipped version 3.1.4 of the product.",
        "It costs 50% more, roughly €40 or £35.",
        "The meeting is at 9:30 AM on July 4th, 1776.",
        "Doors open at 5:45pm and the show runs 2:04:36 long.",
        "We start at 9am sharp.",
        "Dr. Smith will see you now on St. Andrews Road.",
        "This is a state-of-the-art well-designed device.",
        "The file is 10KB and the drive holds 2TB.",
        "Read the docs at https://example.com/docs, or email guy@example.com.",
        "It ran in www.nytimes.com/2026/09/18/tech yesterday.",
    ]
    for input in inputs {
        let once = n.normalize(input)
        #expect(n.normalize(once) == once, "not idempotent: \(input)")
    }
}
