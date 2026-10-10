import Foundation

/// An opening code fence: up to three spaces of indent, then three or more backticks or tildes.
private struct OpeningFence {
  let marker: Unicode.Scalar
  let length: Int
}

private let space: Unicode.Scalar = " "
private let tab: Unicode.Scalar = "\t"

/// The run of fence markers after at most three spaces, and what follows it, as CommonMark reads a
/// fence. Answers are otherwise plain text, so nothing else is interpreted.
private func fenceRun(_ line: Substring.UnicodeScalarView) -> (marker: Unicode.Scalar, length: Int,
  rest: Substring.UnicodeScalarView)? {
  let indent = line.prefix { $0 == space }.count
  guard indent <= 3 else { return nil }
  let afterIndent = line.dropFirst(indent)
  guard let marker = afterIndent.first, marker == "`" || marker == "~" else { return nil }
  let length = afterIndent.prefix { $0 == marker }.count
  guard length >= 3 else { return nil }
  return (marker, length, afterIndent.dropFirst(length))
}

private func openingFence(_ line: Substring.UnicodeScalarView) -> OpeningFence? {
  guard let run = fenceRun(line) else { return nil }
  // The extension's JavaScript `.` stopped at these line separators, so a fence never matches there.
  if run.rest.contains(where: { $0 == "\u{2028}" || $0 == "\u{2029}" }) { return nil }
  // A backtick fence's info string can't contain backticks, so ```x``` is inline code in text.
  if run.marker == "`" && run.rest.contains("`") { return nil }
  return OpeningFence(marker: run.marker, length: run.length)
}

private func closes(_ line: Substring.UnicodeScalarView, _ opening: OpeningFence) -> Bool {
  guard let run = fenceRun(line) else { return false }
  return run.marker == opening.marker && run.length >= opening.length
    && run.rest.allSatisfy { $0 == space || $0 == tab }
}

/// Closes a code block left open by a truncated answer, so text added after it, such as the
/// cut-off notice, is shown as prose instead of being copied as code.
public func closeOpenCodeFence(_ text: String) -> String {
  let lines = normalizeLineEndings(text).unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
  var openFence: OpeningFence?
  var index = 0
  while index < lines.count {
    defer { index += 1 }
    guard let opening = openingFence(lines[index]) else { continue }
    openFence = opening
    while index + 1 < lines.count {
      index += 1
      if closes(lines[index], opening) {
        openFence = nil
        break
      }
    }
  }
  guard let openFence else { return text }
  let separator = text.unicodeScalars.last == "\n" ? "" : "\n"
  return text + separator + String(repeating: String(openFence.marker), count: openFence.length)
}
