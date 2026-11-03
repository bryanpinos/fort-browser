import SwiftUI

/// Safari-style tab strip under the address bar.
struct TabStrip: View {
    @Environment(TabsModel.self) private var tabs

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tabs.tabs) { tab in
                        TabChip(tab: tab, selected: tab.id == tabs.selectedID,
                                select: { tabs.select(tab) }, close: { tabs.close(tab) })
                    }
                }
                .padding(.leading, 12)
            }
            Button { tabs.newTab() } label: {
                Image(systemName: "plus").font(.body.weight(.semibold)).frame(width: 36, height: 30)
            }
            .disabled(!tabs.canOpenTab)
            .accessibilityLabel("New tab")
            .padding(.trailing, 12)
        }
        .padding(.vertical, 6)
        .background(.bar)
    }
}

private struct TabChip: View {
    let tab: BrowserModel
    let selected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: select) {
                Text(tab.displayTitle)
                    .font(.subheadline.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                    .frame(minWidth: 60, maxWidth: 180, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Tab: \(tab.displayTitle)")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("tab")
            Button(action: close) {
                Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close tab")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(selected ? AnyShapeStyle(.background) : AnyShapeStyle(.quaternary),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.tint.opacity(0.5), lineWidth: 1)
            }
        }
    }
}
