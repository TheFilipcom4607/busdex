import Foundation

/// Weather at a catch from Open-Meteo (free, no key). Recent days come from the forecast
/// API, older ones from the ERA5 archive, so old catches can be filled in too.
public enum OpenMeteo {
    public struct Reading: Equatable, Sendable {
        public let code: Int
        public let temperature: Double
    }

    /// The forecast API reaches back ~3 months; the archive lags a few days behind.
    static let forecastReach: TimeInterval = 80 * 86_400

    /// The hour nearest to the catch, in UTC.
    static func hour(of date: Date) -> Date {
        Date(timeIntervalSince1970: ((date.timeIntervalSince1970 + 1800) / 3600).rounded(.down) * 3600)
    }

    private static func utc(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = format
        return f
    }

    /// Coordinates are rounded to ~1 km: plenty for the weather, and less precise than
    /// where you were standing.
    public static func url(latitude: Double, longitude: Double, date: Date, now: Date = Date()) -> URL {
        let hour = hour(of: date)
        let day = utc("yyyy-MM-dd").string(from: hour)
        let recent = now.timeIntervalSince(hour) < forecastReach
        var c = URLComponents(string: recent ? "https://api.open-meteo.com/v1/forecast"
                                             : "https://archive-api.open-meteo.com/v1/archive")!
        c.queryItems = [
            .init(name: "latitude", value: String(format: "%.2f", latitude)),
            .init(name: "longitude", value: String(format: "%.2f", longitude)),
            .init(name: "hourly", value: "temperature_2m,weather_code"),
            .init(name: "start_date", value: day),
            .init(name: "end_date", value: day),
            .init(name: "timezone", value: "GMT"),
        ]
        return c.url!
    }

    private struct Response: Decodable {
        struct Hourly: Decodable {
            let time: [String]
            let temperature_2m: [Double?]
            let weather_code: [Int?]
        }
        let hourly: Hourly
    }

    /// The reading for the catch's hour, or nil if Open-Meteo has no data for it yet.
    public static func reading(from json: Data, at date: Date) -> Reading? {
        guard let r = try? JSONDecoder().decode(Response.self, from: json) else { return nil }
        let key = utc("yyyy-MM-dd'T'HH:mm").string(from: hour(of: date))
        guard let i = r.hourly.time.firstIndex(of: key), i < r.hourly.temperature_2m.count, i < r.hourly.weather_code.count,
              let t = r.hourly.temperature_2m[i], let code = r.hourly.weather_code[i]
        else { return nil }
        return Reading(code: code, temperature: t)
    }
}
