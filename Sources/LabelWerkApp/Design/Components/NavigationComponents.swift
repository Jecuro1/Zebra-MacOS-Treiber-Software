import SwiftUI

/// Tab-Leiste mit gleitender Auswahlkapsel (`matchedGeometryEffect`) und hüpfenden Symbolen.
struct AnimatedTabBar<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let title: (Item) -> String
    let systemImage: (Item) -> String

    @Namespace private var namespace
    @State private var hovered: Item?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReduceMotion) private var appReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    init(items: [Item], selection: Binding<Item>, title: @escaping (Item) -> String,
         systemImage: @escaping (Item) -> String) {
        self.items = items
        self._selection = selection
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(items, id: \.self) { item in
                    tab(item)
                }
            }
            .padding(4)
        }
        .scrollBounceBehavior(.basedOnSize)
        .labelWerkGlass(cornerRadius: 14)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func tab(_ item: Item) -> some View {
        let isSelected = item == selection
        return Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.78)) {
                selection = item
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage(item))
                    .font(.system(size: 12, weight: .semibold))
                    .symbolEffect(.bounce, value: isSelected)
                Text(title(item))
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(hovered == item ? 0.9 : 0.7))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background {
                if isSelected {
                    Capsule()
                        .fill(Theme.brandGradient)
                        .shadow(color: Theme.violet.opacity(0.4), radius: 8, y: 3)
                        .matchedGeometryEffect(id: "selection", in: namespace)
                } else if hovered == item {
                    Capsule().fill(Theme.subtleFill)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { hovered = inside ? item : (hovered == item ? nil : hovered) }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Abschnittsüberschrift mit optionalem Symbol, Untertitel und Aktionsbereich rechts.
struct SectionHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let systemImage: String?
    let trailing: Trailing

    init(_ title: String, subtitle: String? = nil, systemImage: String? = nil,
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.brandGradient)
                    .frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil, systemImage: String? = nil) {
        self.init(title, subtitle: subtitle, systemImage: systemImage) { EmptyView() }
    }
}
