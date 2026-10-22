import Foundation
import CoreFoundation

struct TimeZoneObservation: Equatable, Sendable {
    let identifier: String
    let utcOffsetMinutes: Int
    var offsetText: String {
        let minutes = abs(utcOffsetMinutes)
        return String(format: "UTC%@%02d:%02d", utcOffsetMinutes < 0 ? "−" : "+", minutes / 60, minutes % 60)
    }
    var description: String { "\(identifier) · \(offsetText)" }
}

enum TimeZoneDiagnostics {
    static func system(at date: Date = Date(), zone: TimeZone = .autoupdatingCurrent) -> TimeZoneObservation {
        .init(identifier: zone.identifier, utcOffsetMinutes: zone.secondsFromGMT(for: date) / 60)
    }
    static func parse(_ json: String) -> TimeZoneObservation? {
        guard json.utf8.count <= 4096, let data = json.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let identifier = value["identifier"] as? String, identifier.count <= 100,
              identifier.range(of: "^[A-Za-z0-9_+.-]+(?:/[A-Za-z0-9_+.-]+){0,3}$", options: .regularExpression) != nil,
              let offset = value["utcOffsetMinutes"] as? NSNumber,
              CFGetTypeID(offset) != CFBooleanGetTypeID(),
              offset.doubleValue.isFinite, offset.doubleValue.rounded() == offset.doubleValue,
              (-840...840).contains(offset.intValue) else { return nil }
        return .init(identifier: identifier, utcOffsetMinutes: offset.intValue)
    }
}
