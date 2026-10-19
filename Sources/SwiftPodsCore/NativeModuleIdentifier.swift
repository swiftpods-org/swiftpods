import Foundation

/// Stable ASCII names for modules, independent of locale and external runtimes.
enum NativeModuleIdentifier {
    private static let letters: [Unicode.Scalar: String] = {
        let groups: [String: String] = [
            "A": "ÀÁÂÃÄÅĀĂĄ",
            "AE": "Æ",
            "C": "ÇĆĈĊČ",
            "D": "ÐĎĐ",
            "E": "ÈÉÊËĒĔĖĘĚ",
            "G": "ĜĞĠĢ",
            "H": "ĤĦ",
            "I": "ÌÍÎÏĨĪĬĮİ",
            "IJ": "Ĳ",
            "J": "Ĵ",
            "K": "Ķ",
            "L": "ĹĻĽĿŁ",
            "N": "ÑŃŅŇ",
            "NG": "Ŋ",
            "O": "ÒÓÔÕÖØŌŎŐǪǬ",
            "OE": "Œ",
            "R": "ŔŖŘ",
            "S": "ŚŜŞŠ",
            "SS": "ẞ",
            "T": "ŢŤŦ",
            "Th": "Þ",
            "U": "ÙÚÛÜŨŪŬŮŰŲ",
            "W": "Ŵ",
            "Y": "ÝŶŸ",
            "Z": "ŹŻŽ",
            "a": "àáâãäåāăą",
            "ae": "æ",
            "c": "çćĉċč",
            "d": "ðďđ",
            "e": "èéêëēĕėęě",
            "g": "ĝğġģ",
            "h": "ĥħ",
            "i": "ìíîïĩīĭįı",
            "ij": "ĳ",
            "j": "ĵ",
            "k": "ķĸ",
            "l": "ĺļľŀł",
            "n": "ñńņň",
            "'n": "ŉ",
            "ng": "ŋ",
            "o": "òóôõöøōŏőǫǭ",
            "oe": "œ",
            "r": "ŕŗř",
            "s": "śŝşš",
            "ss": "ß",
            "t": "ţťŧ",
            "th": "þ",
            "u": "ùúûüũūŭůűų",
            "w": "ŵ",
            "x": "×",
            "y": "ýÿŷ",
            "z": "źżž",
        ]
        return Dictionary(
            uniqueKeysWithValues: groups.flatMap { ascii, characters in
                characters.unicodeScalars.map { ($0, ascii) }
            })
    }()

    static func normalize(_ value: String) -> String {
        let ascii = value.unicodeScalars.map { scalar in
            scalar.isASCII ? String(scalar) : letters[scalar] ?? "_"
        }.joined()
        var name = ascii.replacingOccurrences(of: "[^A-Za-z0-9_]", with: "_", options: .regularExpression)
        if name.first?.isNumber == true { name = "_" + name }
        return name.replacingOccurrences(of: "_+", with: "_", options: .regularExpression)
    }
}
