import Foundation

/// `tabor://` links, for widget taps. The app registers the scheme and routes them in RootView.
enum WidgetLink {
    static let scheme = "tabor"

    static let book = URL(string: "\(scheme)://book")!

    static func vehicle(modelId: String, number: Int) -> URL {
        var c = URLComponents()
        c.scheme = scheme
        c.host = "vehicle"
        c.queryItems = [URLQueryItem(name: "model", value: modelId), URLQueryItem(name: "number", value: String(number))]
        return c.url!
    }

    enum Target: Equatable {
        case book
        case vehicle(modelId: String, number: Int)
    }

    static func target(_ url: URL) -> Target? {
        guard url.scheme == scheme else { return nil }
        switch url.host {
        case "book": return .book
        case "vehicle":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard let model = items.first(where: { $0.name == "model" })?.value,
                  let number = items.first(where: { $0.name == "number" })?.value.flatMap(Int.init) else { return nil }
            return .vehicle(modelId: model, number: number)
        default: return nil
        }
    }
}
