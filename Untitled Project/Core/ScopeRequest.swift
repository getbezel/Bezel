import Foundation

struct ScopeRequest {
    enum Action: String { case analyze, inspect, extract, compress }
    let action: Action
    let file: URL
    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "bezel", components.host == "scope",
              let query = components.queryItems, query.count == 2,
              query.filter({ $0.name == "action" }).count == 1,
              query.filter({ $0.name == "path" }).count == 1,
              let rawAction = query.first(where: { $0.name == "action" })?.value,
              let action = Action(rawValue: rawAction),
              let path = query.first(where: { $0.name == "path" })?.value,
              path.hasPrefix("/"), path.utf8.count < 4096, !path.contains("\0") else { return nil }
        self.action = action
        file = URL(fileURLWithPath: path).standardizedFileURL
    }
}
