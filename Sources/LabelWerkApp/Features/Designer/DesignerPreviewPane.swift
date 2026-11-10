import AppKit
import SwiftUI
import LabelWerkKit

/// Live-Vorschau: Vektor oder pixelgenau, Zoom (Regler, ⌘+/⌘−, Zwei-Finger-Zoom), Raster,
/// Lineale, Seitenwahl bei mehreren Etiketten, Elementinspektor und Renderhinweise.
struct DesignerPreviewPane: View {
    let target: DesignerTarget
    let preview: DesignerPreviewState
    let printTrigger: Int
    let reduceMotion: Bool

    @AppStorage("designer.previewStyle") private var style: DesignerPreviewStyle = .vector
    @AppStorage("designer.showsGrid") private var showsGrid = false
    @AppStorage("designer.showsRulers") private var showsRulers = true
    @AppStorage("designer.showsInspector") private var showsInspector = true
    @State private var zoom: CGFloat = 1
    @State private var pinchBase: CGFloat?
    @State private var inspectorTab: DesignerInspectorTab = .elements

    private static let zoomRange: ClosedRange<CGFloat> = 0.5...4

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider().opacity(0.6)
            canvasArea
            Divider().opacity(0.6)
            statusBar
            if showsInspector {
                Divider().opacity(0.6)
                DesignerInspector(label: preview.currentLabel, preview: preview, tab: $inspectorTab,
                                  reduceMotion: reduceMotion)
                    .frame(height: 196)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .labelWerkGlass(cornerRadius: Theme.Metrics.corner)
        .animation(reduceMotion ? nil : Motion.spring, value: showsInspector)
        .task(id: DesignerRasterRequest(generation: preview.generation, index: preview.labelIndex, style: style)) {
            await preview.rasterizeIfNeeded(style: style)
        }
    }

    // MARK: Bedienleiste

    private var controls: some View {
        HStack(spacing: 8) {
            DesignerChoiceBar(items: DesignerPreviewStyle.allCases, selection: $style, reduceMotion: reduceMotion,
                              title: { $0.title }, systemImage: { $0.systemImage })
                .frame(width: 216)
                .help(tr("Vektor: scharf in jeder Zoomstufe · Pixelgenau: exakt wie der Drucker"))
            Spacer(minLength: 4)
            if preview.isRendering || (style == .pixel && preview.isRasterizing) {
                ProgressView()
                    .controlSize(.small)
                    .transition(.opacity.combined(with: .scale))
            }
            toggleButton(isOn: $showsGrid, systemImage: "square.grid.3x3", help: tr("Raster (5 mm) einblenden"))
            toggleButton(isOn: $showsRulers, systemImage: "ruler", help: tr("Lineale in Millimetern"))
            toggleButton(isOn: $showsInspector, systemImage: "list.bullet.rectangle",
                         help: tr("Elemente und Hinweise anzeigen"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .animation(reduceMotion ? nil : Motion.snappy, value: preview.isRendering)
    }

    private func toggleButton(isOn: Binding<Bool>, systemImage: String, help: String) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : Motion.snappy) { isOn.wrappedValue.toggle() }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isOn.wrappedValue ? Color.white : Color.primary.opacity(0.7))
                .frame(width: 28, height: 24)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isOn.wrappedValue ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Theme.subtleFill))
                }
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(DesignerPressStyle())
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
    }

    // MARK: Zeichenfläche

    private var canvasArea: some View {
        GeometryReader { geo in
            ZStack {
                if let label = preview.currentLabel {
                    let rulerSpace: CGFloat = showsRulers ? 22 : 0
                    let available = CGSize(width: max(40, geo.size.width - 56 - rulerSpace),
                                           height: max(40, geo.size.height - 56 - rulerSpace))
                    let fit = DesignerCanvasMath.fitSize(widthDots: label.widthDots, heightDots: label.heightDots,
                                                         in: available)
                    let size = CGSize(width: fit.width * zoom, height: fit.height * zoom)
                    ScrollView([.horizontal, .vertical]) {
                        stage(label, size: size)
                            .padding(24)
                            .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                    }
                } else if preview.document == nil {
                    VStack(spacing: 10) {
                        ProgressRing(progress: nil, size: 30, lineWidth: 3)
                        Text(tr("Vorschau wird berechnet …"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    VStack(spacing: 10) {
                        IconBadge(systemImage: "doc.text.magnifyingglass", tint: Theme.violet, size: 48)
                        Text(tr("Noch kein Etikett"))
                            .font(Theme.Typography.headline)
                        Text(tr("Wähle eine Vorlage oder schreibe ZPL zwischen ^XA und ^XZ."))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(24)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .overlay(alignment: .bottomTrailing) {
            if preview.currentLabel != nil {
                zoomControls
                    .padding(10)
            }
        }
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    let base = pinchBase ?? zoom
                    if pinchBase == nil { pinchBase = zoom }
                    zoom = (base * value.magnification).clamped(to: Self.zoomRange)
                }
                .onEnded { _ in pinchBase = nil }
        )
    }

    /// Etikett mit Linealen, Sendeanimation und Seitenübergang.
    @ViewBuilder
    private func stage(_ label: RenderedLabel, size: CGSize) -> some View {
        let dpmm = max(1, label.dotsPerMM)
        let widthMM = Double(label.widthDots) / Double(dpmm)
        let heightMM = Double(label.heightDots) / Double(dpmm)
        let highlight = preview.highlightedElement
        let highlightRect = highlight.flatMap { DesignerCanvasMath.displayRect(of: $0, in: label) }
        VStack(alignment: .leading, spacing: 4) {
            if showsRulers {
                HStack(spacing: 4) {
                    Color.clear.frame(width: 18, height: 18)
                    DesignerRuler(axis: .horizontal, lengthMM: widthMM,
                                  highlight: highlightRect.map { DesignerCanvasMath.span($0, horizontal: true, dotsPerMM: dpmm) })
                        .frame(width: size.width, height: 18)
                }
                .transition(.opacity)
            }
            HStack(alignment: .top, spacing: 4) {
                if showsRulers {
                    DesignerRuler(axis: .vertical, lengthMM: heightMM,
                                  highlight: highlightRect.map { DesignerCanvasMath.span($0, horizontal: false, dotsPerMM: dpmm) })
                        .frame(width: 18, height: size.height)
                        .transition(.opacity)
                }
                // ZStack: Beim Seitenwechsel liegen altes und neues Etikett übereinander.
                ZStack {
                    sheet(label, widthMM: widthMM, heightMM: heightMM, size: size,
                          highlight: highlight, highlightRect: highlightRect)
                }
                .frame(width: size.width, height: size.height)
            }
        }
    }

    private func sheet(_ label: RenderedLabel, widthMM: Double, heightMM: Double, size: CGSize,
                       highlight: Int?, highlightRect: CGRect?) -> some View {
        LabelSheet(widthMM: widthMM, heightMM: heightMM) {
            ZStack {
                switch style {
                case .vector:
                    LabelCanvas(label: label, showsGrid: showsGrid, highlightedElement: highlight)
                case .pixel:
                    if let raster = preview.raster {
                        BitmapPreview(bitmap: raster)
                            .opacity(preview.isRasterStale ? 0.55 : 1)
                    } else {
                        Color.white
                    }
                    if showsGrid {
                        DesignerGridOverlay(widthDots: label.widthDots, heightDots: label.heightDots,
                                            dotsPerMM: label.dotsPerMM)
                    }
                    DesignerHighlightOverlay(rect: highlightRect,
                                             labelSize: CGSize(width: label.widthDots, height: label.heightDots))
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                preview.hover(DesignerCanvasMath.element(at: location, viewSize: size, in: label), fromCanvas: true)
            case .ended:
                preview.hover(nil, fromCanvas: true)
            }
        }
        .onTapGesture {
            withAnimation(reduceMotion ? nil : Motion.snappy) { preview.togglePin(preview.hoveredElement) }
        }
        .id(preview.labelIndex)
        .transition(reduceMotion ? .opacity : .push(from: preview.pagingForward ? .trailing : .leading))
        .keyframeAnimator(initialValue: DesignerPrintMotion(), trigger: reduceMotion ? 0 : printTrigger) { content, value in
            content
                .scaleEffect(value.scale)
                .offset(y: value.offset)
                .opacity(value.opacity)
        } keyframes: { _ in
            KeyframeTrack(\.offset) {
                CubicKeyframe(-16, duration: 0.16)
                CubicKeyframe(340, duration: 0.38)
                MoveKeyframe(-140)
                SpringKeyframe(0, duration: 0.6, spring: .bouncy)
            }
            KeyframeTrack(\.scale) {
                CubicKeyframe(1.03, duration: 0.16)
                CubicKeyframe(0.86, duration: 0.38)
                MoveKeyframe(0.94)
                SpringKeyframe(1, duration: 0.6, spring: .bouncy)
            }
            KeyframeTrack(\.opacity) {
                LinearKeyframe(1, duration: 0.22)
                LinearKeyframe(0, duration: 0.32)
                MoveKeyframe(0)
                LinearKeyframe(1, duration: 0.35)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr("Etikettenvorschau"))
    }

    // MARK: Zoom

    private var zoomControls: some View {
        HStack(spacing: 8) {
            Button { setZoom(zoom / 1.25) } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.plain)
            .keyboardShortcut("-", modifiers: [.command])
            .help(tr("Verkleinern (⌘−)"))
            Slider(value: $zoom, in: Self.zoomRange)
                .controlSize(.mini)
                .frame(width: 90)
            Button { setZoom(zoom * 1.25) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.plain)
            .keyboardShortcut("+", modifiers: [.command])
            .help(tr("Vergrößern (⌘+)"))
            Text(Double(zoom), format: .percent.precision(.fractionLength(0)))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .frame(width: 40)
                .contentTransition(.numericText(value: Double(zoom)))
            Button { setZoom(1) } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
            }
            .buttonStyle(.plain)
            .keyboardShortcut("0", modifiers: [.command])
            .disabled(abs(zoom - 1) < 0.001)
            .help(tr("Einpassen (⌘0)"))
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .labelWerkGlass(cornerRadius: 12)
    }

    private func setZoom(_ value: CGFloat) {
        withAnimation(reduceMotion ? nil : Motion.snappy) {
            zoom = value.clamped(to: Self.zoomRange)
        }
    }

    // MARK: Statuszeile

    private var statusBar: some View {
        let labels = preview.labels
        return HStack(spacing: 10) {
            if labels.count > 1 {
                pager(count: labels.count)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            Spacer(minLength: 6)
            readout
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: 30)
        .animation(reduceMotion ? nil : Motion.snappy, value: labels.count)
        .animation(reduceMotion ? nil : Motion.snappy, value: preview.highlightedElement)
    }

    private func pager(count: Int) -> some View {
        HStack(spacing: 8) {
            Button { page(by: -1) } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.labelWerkPlain)
            .disabled(preview.labelIndex == 0)
            HStack(spacing: 4) {
                ForEach(0..<min(count, 12), id: \.self) { index in
                    Capsule()
                        .fill(index == preview.labelIndex ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Color.secondary.opacity(0.3)))
                        .frame(width: index == preview.labelIndex ? 16 : 6, height: 6)
                        .contentShape(Rectangle())
                        .onTapGesture { select(index) }
                }
            }
            Text(tr("Etikett %d von %d", preview.labelIndex + 1, count))
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .contentTransition(.numericText(value: Double(preview.labelIndex)))
            Button { page(by: 1) } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.labelWerkPlain)
            .disabled(preview.labelIndex >= count - 1)
        }
        .animation(reduceMotion ? nil : Motion.spring, value: preview.labelIndex)
    }

    @ViewBuilder
    private var readout: some View {
        if let label = preview.currentLabel {
            if let index = preview.highlightedElement, label.elements.indices.contains(index) {
                let element = label.elements[index]
                let info = DesignerElementInfo.make(element)
                let box = element.boundingBox
                HStack(spacing: 6) {
                    Image(systemName: info.systemImage)
                        .foregroundStyle(info.tint)
                    Text(info.title)
                        .fontWeight(.semibold)
                    Text(DesignerFormat.position(x: box.x, y: box.y, dotsPerMM: label.dotsPerMM))
                    Text(DesignerFormat.size(width: box.width, height: box.height, dotsPerMM: label.dotsPerMM))
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11.5).monospacedDigit())
                .lineLimit(1)
                .transition(.opacity)
            } else {
                HStack(spacing: 6) {
                    if label.widthDots != target.widthDots || label.heightDots != target.heightDots {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warning)
                            .help(tr("Die Formatgröße (^PW/^LL) weicht vom Zieletikett ab: %@ · %d × %d Punkte",
                                     target.sizeText, target.widthDots, target.heightDots))
                    }
                    Text(summary(of: label))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                }
                .font(.system(size: 11.5).monospacedDigit())
                .transition(.opacity)
            }
        }
    }

    private func summary(of label: RenderedLabel) -> String {
        var parts = [
            DesignerFormat.size(width: label.widthDots, height: label.heightDots, dotsPerMM: label.dotsPerMM),
            tr("%d × %d Punkte", label.widthDots, label.heightDots),
        ]
        if label.quantity > 1 { parts.append(tr("%d Stück", label.quantity)) }
        if label.inverted { parts.append(tr("gedreht")) }
        if label.mirrored { parts.append(tr("gespiegelt")) }
        parts.append(tr("%d ms", preview.renderMilliseconds))
        return parts.joined(separator: " · ")
    }

    private func page(by delta: Int) {
        select(preview.labelIndex + delta)
    }

    private func select(_ index: Int) {
        withAnimation(reduceMotion ? nil : Motion.spring) { preview.select(index) }
    }
}

// MARK: - Inspektor

/// Elementliste (Position & Größe in mm, Hover hebt in der Vorschau hervor, Klick heftet an)
/// und Hinweise des Interpreters.
struct DesignerInspector: View {
    let label: RenderedLabel?
    let preview: DesignerPreviewState
    @Binding var tab: DesignerInspectorTab
    let reduceMotion: Bool

    private var elementCount: Int { label?.elements.count ?? 0 }
    private var warningCount: Int { label?.warnings.count ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                DesignerChoiceBar(items: DesignerInspectorTab.allCases, selection: $tab, reduceMotion: reduceMotion,
                                  title: { title(for: $0) }, systemImage: { $0.systemImage })
                    .frame(width: 270)
                Spacer()
                if warningCount > 0 && tab == .elements {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                        .symbolEffect(.pulse, options: .repeat(2), value: warningCount)
                        .help(tr("Der Interpreter hat Hinweise zu diesem Etikett"))
                }
            }
            ZStack {
                switch tab {
                case .elements:
                    elementList
                        .transition(.opacity)
                case .warnings:
                    warningList
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? nil : Motion.snappy, value: tab)
        }
        .padding(10)
    }

    private func title(for tab: DesignerInspectorTab) -> String {
        switch tab {
        case .elements: return tr("Elemente (%d)", elementCount)
        case .warnings: return tr("Hinweise (%d)", warningCount)
        }
    }

    @ViewBuilder
    private var elementList: some View {
        if let label, !label.elements.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(label.elements.enumerated()), id: \.offset) { index, element in
                            DesignerElementRow(index: index, element: element, dotsPerMM: label.dotsPerMM,
                                               isHighlighted: preview.highlightedElement == index,
                                               isPinned: preview.pinnedElement == index)
                                .id(index)
                                .onHover { inside in
                                    if inside {
                                        preview.hover(index, fromCanvas: false)
                                    } else {
                                        preview.endHover(index)
                                    }
                                }
                                .onTapGesture {
                                    withAnimation(reduceMotion ? nil : Motion.snappy) { preview.togglePin(index) }
                                }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onChange(of: preview.hoveredElement) { _, newValue in
                    guard preview.hoverFromCanvas, let newValue else { return }
                    withAnimation(reduceMotion ? nil : Motion.snappy) { proxy.scrollTo(newValue, anchor: .center) }
                }
            }
        } else {
            Text(tr("Keine Elemente auf diesem Etikett."))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var warningList: some View {
        let warnings = label?.warnings ?? []
        if warnings.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Theme.ready)
                    .symbolEffect(.bounce, value: tab)
                Text(tr("Keine Hinweise – alle Befehle wurden verstanden."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.warning)
                            Text(warning.command)
                                .font(Theme.Typography.codeSmall)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Theme.warning.opacity(0.14), in: Capsule())
                            Text(warning.message)
                                .font(.system(size: 12))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(4)
            }
        }
    }
}

private struct DesignerElementRow: View {
    let index: Int
    let element: LabelElement
    let dotsPerMM: Int
    let isHighlighted: Bool
    let isPinned: Bool

    var body: some View {
        let info = DesignerElementInfo.make(element)
        let box = element.boundingBox
        HStack(spacing: 8) {
            Text(verbatim: String(index + 1))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 24, alignment: .trailing)
            Image(systemName: info.systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(info.tint)
                .frame(width: 18)
            Text(info.title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Text(info.detail)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Text(DesignerFormat.position(x: box.x, y: box.y, dotsPerMM: dotsPerMM))
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(DesignerFormat.size(width: box.width, height: box.height, dotsPerMM: dotsPerMM))
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Image(systemName: "pin.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.accent)
                .opacity(isPinned ? 1 : 0)
                .scaleEffect(isPinned ? 1 : 0.4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHighlighted ? Theme.accent.opacity(0.14) : Color.clear)
        )
        .contentShape(Rectangle())
        .animation(Motion.snappy, value: isHighlighted)
        .animation(Motion.bouncy, value: isPinned)
    }
}
