import Foundation

// This module was ported from the Chrome extension's TypeScript, which worked on JavaScript
// strings, and its golden fixtures pin that behavior. These helpers keep it where Swift's differs:
// Swift compares and counts characters (grapheme clusters), so "\r\n" is one character, and
// Foundation's whitespace differs from JavaScript's.

/// The whitespace JavaScript's `trim()` and `\s` remove. Foundation's sets differ for U+FEFF,
/// U+0085 and U+200B.
let javaScriptWhitespace = CharacterSet(charactersIn:
  "\u{0009}\u{000A}\u{000B}\u{000C}\u{000D}\u{0020}\u{00A0}\u{1680}" +
  "\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}" +
  "\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}")

extension String {
  /// JavaScript's `trim()`.
  public var jsTrimmed: String { trimmingCharacters(in: javaScriptWhitespace) }

  /// Whether `trim()` would leave nothing.
  var isBlank: Bool { unicodeScalars.allSatisfy { javaScriptWhitespace.contains($0) } }

  /// JavaScript's `startsWith`, which compares code points rather than characters.
  func jsHasPrefix(_ prefix: String) -> Bool { unicodeScalars.starts(with: prefix.unicodeScalars) }

  /// JavaScript's `===`. Swift's `==` also matches canonically equivalent strings.
  func jsEquals(_ other: String) -> Bool { unicodeScalars.elementsEqual(other.unicodeScalars) }

  /// At most `limit` UTF-16 code units, like JavaScript's `slice(0, limit)`, except that a
  /// surrogate pair is never split.
  func prefix(utf16Units limit: Int) -> String {
    var count = 0
    var scalars = String.UnicodeScalarView()
    for scalar in unicodeScalars {
      count += scalar.utf16.count
      if count > limit { break }
      scalars.append(scalar)
    }
    return String(scalars)
  }
}

/// Replaces CRLF and CR line endings with LF.
/// Other whitespace and Markdown-looking symbols are part of the answer and stay.
func normalizeLineEndings(_ text: String) -> String {
  var result = String.UnicodeScalarView()
  var afterCR = false
  for scalar in text.unicodeScalars {
    if scalar == "\n" && afterCR {
      afterCR = false
      continue
    }
    afterCR = scalar == "\r"
    result.append(afterCR ? "\n" : scalar)
  }
  return String(result)
}

/// A whole number with comma grouping, like `toLocaleString()` in an English locale.
public func groupedDigits(_ value: Int) -> String {
  let digits = String(value.magnitude)
  var grouped = ""
  for (index, digit) in digits.enumerated() {
    if index > 0 && (digits.count - index) % 3 == 0 { grouped.append(",") }
    grouped.append(digit)
  }
  return value < 0 ? "-" + grouped : grouped
}
