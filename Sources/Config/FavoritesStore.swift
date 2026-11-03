import Foundation
import Observation

/// Start-page favorites: the parent's (from the config, shared by every
/// device using it) plus each kid's own, kept on this iPad only.
@Observable
final class FavoritesStore {
    typealias Favorite = GateConfig.Favorite

    private(set) var kidFavorites: [Favorite]
    private let key: String

    init(key: String = "fort.kidFavorites") {
        self.key = key
        kidFavorites = (UserDefaults.standard.data(forKey: key))
            .flatMap { try? JSONDecoder().decode([Favorite].self, from: $0) } ?? []
    }

    /// Parent favorites first, then the kid's, without duplicates.
    func all(parent: [Favorite]?) -> [(favorite: Favorite, isKids: Bool)] {
        var seen = Set<String>()
        var result: [(Favorite, Bool)] = []
        for (f, kids) in (parent ?? []).map({ ($0, false) }) + kidFavorites.map({ ($0, true) }) {
            if seen.insert(Self.identity(f.url)).inserted { result.append((f, kids)) }
        }
        return result
    }

    func isFavorite(_ url: URL?, parent: [Favorite]?) -> Bool {
        guard let url else { return false }
        let id = Self.identity(url)
        return ((parent ?? []) + kidFavorites).contains { Self.identity($0.url) == id }
    }

    /// Adds or removes `url` from the kid's favorites (parent ones can only
    /// be changed in Parent settings).
    func toggle(_ url: URL, title: String) {
        let id = Self.identity(url)
        if let i = kidFavorites.firstIndex(where: { Self.identity($0.url) == id }) {
            kidFavorites.remove(at: i)
        } else {
            let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
            kidFavorites.append(Favorite(name: name.isEmpty ? (url.host ?? url.absoluteString) : String(name.prefix(40)), url: url))
        }
        save()
    }

    func remove(_ favorite: Favorite) {
        kidFavorites.removeAll { Self.identity($0.url) == Self.identity(favorite.url) }
        save()
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(kidFavorites), forKey: key)
    }

    /// Same site regardless of scheme, "www.", trailing slash or case.
    static func identity(_ url: URL) -> String {
        var host = (url.host ?? "").lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        return host + path + (url.query.map { "?" + $0 } ?? "")
    }

    /// Parses Parent settings' favorites text: one per line, "URL Name".
    static func parse(_ text: String) -> [Favorite] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard let first = parts.first, let url = BrowserModel.destination(for: first),
                  url.host != "www.google.com" || first.contains("google") else { return nil }
            let name = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : (url.host ?? first)
            return Favorite(name: name, url: url)
        }
    }

    static func format(_ favorites: [Favorite]?) -> String {
        (favorites ?? []).map { "\($0.url.absoluteString) \($0.name)" }.joined(separator: "\n")
    }
}
