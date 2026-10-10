import Foundation

let maxFollowupCharacters = 50_000

// ECMAScript String.trim() whitespace, shared with the extension's runtime validators. Foundation
// differs for U+FEFF, U+0085 and U+200B; mismatches could turn harmless blank input into disconnects.
private let protocolWhitespace = CharacterSet(charactersIn:
  "\u{0009}\u{000A}\u{000B}\u{000C}\u{000D}\u{0020}\u{00A0}\u{1680}" +
  "\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}" +
  "\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}")

func trimProtocolText(_ value: String) -> String { value.trimmingCharacters(in: protocolWhitespace) }

func inputFitsLimits(_ value: String, maximum: Int) -> Bool {
  // The preference counts Unicode code points, matching the extension's for...of counter.
  // The independent wire bound counts UTF-16 code units, matching JavaScript string.length.
  value.unicodeScalars.count <= maximum && value.utf16.count <= maxFollowupCharacters
}
