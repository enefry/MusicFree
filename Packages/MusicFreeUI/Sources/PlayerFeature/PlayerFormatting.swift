import Foundation

enum PlayerFormatting {
  static func seconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
  }

  static func duration(_ duration: Duration?) -> String {
    guard let duration else {
      return "--:--"
    }

    return clock(seconds(duration))
  }

  static func remaining(position: Duration?, duration: Duration?) -> String {
    guard let duration else {
      return "--:--"
    }

    let remainingSeconds = max(0, seconds(duration) - seconds(position ?? .zero))
    return "-\(clock(remainingSeconds))"
  }

  private static func clock(_ duration: Double) -> String {
    let totalSeconds = max(0, Int(duration.rounded(.down)))
    let hours = totalSeconds / 3_600
    let minutes = (totalSeconds % 3_600) / 60
    let seconds = totalSeconds % 60

    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%d:%02d", minutes, seconds)
  }
}
