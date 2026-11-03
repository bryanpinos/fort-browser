import SwiftUI

/// Full-tab page shown when Fort blocks a site. Gentle and kid-facing: it
/// says what happened without making the kid feel in trouble.
struct BlockedPageView: View {
    let block: BrowserModel.Block
    let canGoBack: Bool
    let goBack: () -> Void
    let startPage: () -> Void

    // Twilight indigo/violet like the app icon; amber accents. No red/green.
    private static let skyTop = Color(red: 0.18, green: 0.23, blue: 0.55)
    private static let skyBottom = Color(red: 0.42, green: 0.31, blue: 0.76)
    private static let amber = Color(red: 0.96, green: 0.62, blue: 0.04)

    private var title: String {
        block.reason == .download ? "Fort doesn't download files" : "This one stays outside the fort"
    }

    private var detail: String {
        let site = block.host.isEmpty ? "That site" : block.host
        switch block.reason {
        case .notAllowed: return "\(site) isn't on the list of places Fort can visit."
        case .blockedAtHome: return "Your home's filter keeps \(site) out."
        case .download: return "Fort only shows web pages. If you need this file, ask a grown-up."
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Self.skyTop, Self.skyBottom], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            stars
            VStack(spacing: 22) {
                Image(systemName: block.reason == .download ? "doc.badge.ellipsis" : "tent.fill")
                    .font(.system(size: 96, weight: .regular))
                    .foregroundStyle(.white, Self.amber)
                    .symbolRenderingMode(.palette)
                    .shadow(color: Self.amber.opacity(0.45), radius: 24)
                Text(title)
                    .font(.system(.largeTitle, design: .rounded).bold())
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 40)
                HStack(spacing: 16) {
                    if canGoBack {
                        Button(action: goBack) {
                            Label("Go back", systemImage: "chevron.left").frame(minWidth: 140)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Self.amber)
                    }
                    Button(action: startPage) {
                        Label("Start page", systemImage: "square.grid.2x2").frame(minWidth: 140)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
                .controlSize(.large)
                .padding(.top, 8)
            }
            .padding(32)
            .frame(maxWidth: 640)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("blocked-page")
    }

    private var stars: some View {
        GeometryReader { geo in
            ForEach(Array(Self.starPositions.enumerated()), id: \.offset) { _, p in
                Circle()
                    .fill(.white.opacity(p.z))
                    .frame(width: 4 + 4 * p.z, height: 4 + 4 * p.z)
                    .position(x: geo.size.width * p.x, y: geo.size.height * p.y)
            }
        }
        .allowsHitTesting(false)
    }

    private static let starPositions: [(x: Double, y: Double, z: Double)] = [
        (0.12, 0.10, 0.9), (0.28, 0.06, 0.6), (0.71, 0.08, 0.8), (0.86, 0.18, 0.5),
        (0.08, 0.32, 0.5), (0.93, 0.36, 0.7), (0.20, 0.82, 0.4), (0.80, 0.86, 0.5),
    ]
}
