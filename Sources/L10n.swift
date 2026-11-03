// Kadr — localization. English is the development language: the English text in code is the key,
// Russian lives in Resources/ru.lproj/Localizable.strings. The language follows the system
// (or the «Language» setting, which writes AppleLanguages for this app and applies after a restart).
import Foundation

/// Localized UI string. `en` is both the key and the English text.
func L(_ en: String) -> String { Bundle.main.localizedString(forKey: en, value: en, table: nil) }

/// Localized format string: `Lf("Copied %d items", n)`. Keys keep the same format specifiers in every language.
func Lf(_ en: String, _ args: CVarArg...) -> String { String(format: L(en), locale: UILocale.current, arguments: args) }

/// Plural: English picks `one` / `other`. The Russian value for the key `one` holds three forms "1|2–4|5+",
/// e.g. "item" = "запись|записи|записей". Returns the word only (callers add the number).
func Lp(_ n: Int, _ one: String, _ other: String) -> String {
    let ru = L(one)
    if UILocale.isRussian, ru.contains("|") {
        let f = ru.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        if f.count == 3 { return russianPlural(n, f[0], f[1], f[2]) }
    }
    return n == 1 ? one : other
}

enum UILocale {
    /// Language the UI is actually shown in (one of the bundle's localizations).
    static var language: String { Bundle.main.preferredLocalizations.first ?? "en" }
    static var isRussian: Bool { language == "ru" }
    /// Locale for dates and numbers that matches the UI language (not just the system region).
    static var current: Locale { Locale(identifier: isRussian ? "ru_RU" : "en_US") }
}
