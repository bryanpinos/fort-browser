import SwiftUI

/// New-tab page: big tiles for the parent's favorites and the kid's own.
struct StartPageView: View {
    @Environment(ConfigStore.self) private var store
    @Environment(FavoritesStore.self) private var favorites
    let open: (URL) -> Void

    var body: some View {
        let items = favorites.all(parent: store.config.favorites)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Where to?")
                    .font(.largeTitle.bold())
                if items.isEmpty {
                    Label("Tap the star on a site to add it here.", systemImage: "star")
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 24)], spacing: 24) {
                    ForEach(items, id: \.favorite) { item in
                        Button { open(item.favorite.url) } label: { FavoriteTile(favorite: item.favorite) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.favorite.name)
                            .accessibilityIdentifier("favorite-tile")
                            .contextMenu {
                                if item.isKids {
                                    Button("Remove", systemImage: "star.slash", role: .destructive) {
                                        favorites.remove(item.favorite)
                                    }
                                }
                            }
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .accessibilityIdentifier("start-page")
    }
}

private struct FavoriteTile: View {
    let favorite: GateConfig.Favorite

    // Distinct, kid-friendly colors with no red/green pairs.
    private static let palette: [Color] = [
        Color(red: 0.31, green: 0.27, blue: 0.90), // indigo
        Color(red: 0.15, green: 0.39, blue: 0.92), // blue
        Color(red: 0.49, green: 0.23, blue: 0.93), // violet
        Color(red: 0.92, green: 0.35, blue: 0.05), // orange
        Color(red: 0.86, green: 0.15, blue: 0.47), // pink
        Color(red: 0.01, green: 0.52, blue: 0.78), // sky
        Color(red: 0.85, green: 0.47, blue: 0.02), // amber
        Color(red: 0.28, green: 0.33, blue: 0.41), // slate
    ]

    private var color: Color {
        // Stable across launches (unlike hashValue).
        let sum = (favorite.url.host ?? favorite.name).unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return Self.palette[sum % Self.palette.count]
    }

    var body: some View {
        VStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(color.gradient)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Text(String(favorite.name.prefix(1)).uppercased())
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
            Text(favorite.name)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
        }
    }
}
