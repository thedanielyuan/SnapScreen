import Foundation

private enum GeometryTestError: Error { case failed(String) }

func runGeometryTests() throws -> Int {
  var count = 0
  func check(_ value: Bool, _ name: String) throws {
    guard value else { throw GeometryTestError.failed(name) }
    count += 1
  }

  try check(NormalizedRect(x: 0, y: 0, width: 1, height: 1).isValid, "full-image normalized crop")
  try check(!NormalizedRect(x: -0.1, y: 0, width: 1, height: 1).isValid, "negative crop rejected")
  try check(!NormalizedRect(x: 0, y: 0, width: 0, height: 1).isValid, "empty crop rejected")
  try check(!NormalizedRect(x: 0.8, y: 0, width: 0.5, height: 1).isValid, "outside crop rejected")
  try check(!NormalizedRect(x: .nan, y: 0, width: 1, height: 1).isValid, "nonfinite crop rejected")
  let landscape = fittedImageRect(CGSize(width: 2000, height: 1000), in: CGRect(x: 0, y: 0, width: 1000, height: 1000))
  try check(landscape == CGRect(x: 12, y: 256, width: 976, height: 488), "fitted landscape mapping")
  let portrait = fittedImageRect(CGSize(width: 1000, height: 2000), in: CGRect(x: 0, y: 0, width: 1000, height: 1000))
  try check(portrait == CGRect(x: 256, y: 12, width: 488, height: 976), "fitted portrait mapping")
  try check(fittedImageRect(.zero, in: CGRect(x: 0, y: 0, width: 1000, height: 1000)) == .zero, "empty fitted image")
  let fitted = CGRect(x: 12, y: 12, width: 1000, height: 500)
  try check(selectionMeetsMinimum(CGRect(x: 0.1, y: 0.1, width: 0.005, height: 0.01), in: fitted), "minimum drag submits")
  try check(!selectionMeetsMinimum(.zero, in: fitted), "click cancels")
  try check(!selectionMeetsMinimum(CGRect(x: 0, y: 0, width: 0.004, height: 1), in: fitted), "tiny drag cancels")
  let edge = CGRect(x: 100, y: 100, width: 600, height: 400)
  try check(isNearFrameEdge(CGPoint(x: 96, y: 300), edge), "outer edge raises shield")
  try check(isNearFrameEdge(CGPoint(x: 695, y: 300), edge), "inner edge raises shield")
  try check(!isNearFrameEdge(CGPoint(x: 400, y: 300), edge), "interior leaves shield transparent")
  return count
}
