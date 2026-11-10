import SwiftUI
import LabelWerkKit

/// Schritte des Erststart-Assistenten.
enum OnboardingStep: Int, CaseIterable, Identifiable, Hashable {
    case welcome
    case driver
    case printers
    case notifications
    case done

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome: return tr("Willkommen")
        case .driver: return tr("Treiber")
        case .printers: return tr("Drucker")
        case .notifications: return tr("Mitteilungen")
        case .done: return tr("Fertig")
        }
    }

    var systemImage: String {
        switch self {
        case .welcome: return "sparkles"
        case .driver: return "shippingbox"
        case .printers: return "printer"
        case .notifications: return "bell.badge"
        case .done: return "checkmark.seal"
        }
    }

    var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }
}

/// Erststart-Assistent: Willkommen → Treiber → Drucker → Mitteilungen → Fertig.
///
/// Animierter Markenhintergrund, richtungsabhängige Seitenübergänge, Fortschrittspunkte mit
/// gleitender Markierung, Tastatursteuerung (← → und ↩) sowie „Überspringen“.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    @State private var step: OnboardingStep = .welcome
    @State private var forward = true
    @State private var visited: Set<OnboardingStep> = [.welcome]
    @State private var showManualAdd = false
    @Namespace private var namespace

    init() {}

    private var reduceMotion: Bool { systemReduceMotion || model.preferences.reduceMotion }

    var body: some View {
        ZStack {
            AnimatedBackground(style: .brand)
                .ignoresSafeArea()
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.35)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 28)
                    .padding(.top, 18)

                GeometryReader { proxy in
                    ZStack {
                        page(for: step)
                            .id(step)
                            .transition(pageTransition)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                }

                bottomBar
                    .padding(.horizontal, 28)
                    .padding(.bottom, 20)
                    .padding(.top, 8)
            }
        }
        .frame(minWidth: 760, idealWidth: 900, minHeight: 560, idealHeight: 680)
        .background { keyboardShortcuts }
        .sheet(isPresented: $showManualAdd) {
            AddPrinterView(initialTab: .manual)
                .environment(model)
        }
        .onChange(of: step) { _, newStep in
            if newStep == .done, model.preferences.playSounds {
                SoundService.play(.success)
            }
        }
    }

    // MARK: Seiten

    @ViewBuilder
    private func page(for step: OnboardingStep) -> some View {
        GeometryReader { proxy in
            ScrollView {
                pageContent(step)
                    .frame(maxWidth: 880)
                    .padding(.horizontal, 36)
                    .padding(.vertical, 12)
                    .frame(width: proxy.size.width)
                    .frame(minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    @ViewBuilder
    private func pageContent(_ step: OnboardingStep) -> some View {
        switch step {
        case .welcome:
            OnboardingWelcomePage(reduceMotion: reduceMotion)
        case .driver:
            OnboardingDriverPage(reduceMotion: reduceMotion)
        case .printers:
            OnboardingPrintersPage(reduceMotion: reduceMotion) {
                showManualAdd = true
            }
        case .notifications:
            OnboardingNotificationsPage(reduceMotion: reduceMotion)
        case .done:
            OnboardingDonePage(reduceMotion: reduceMotion)
        }
    }

    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let distance: CGFloat = 110
        return .asymmetric(
            insertion: .modifier(
                active: OnboardingPageEffect(offset: forward ? distance : -distance, blur: 10, opacity: 0, scale: 0.97),
                identity: OnboardingPageEffect(offset: 0, blur: 0, opacity: 1, scale: 1)
            ),
            removal: .modifier(
                active: OnboardingPageEffect(offset: forward ? -distance : distance, blur: 10, opacity: 0, scale: 0.97),
                identity: OnboardingPageEffect(offset: 0, blur: 0, opacity: 1, scale: 1)
            )
        )
    }

    // MARK: Kopf- und Fußleiste

    private var topBar: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.brandGradient)
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: "printer.filled.and.paper")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .shadow(color: Theme.violet.opacity(0.4), radius: 6, y: 2)
            Text(verbatim: "LabelWerk")
                .font(.system(size: 15, weight: .bold, design: .rounded))
            Text(tr("Schritt %d von %d", step.rawValue + 1, OnboardingStep.allCases.count))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .contentTransition(.numericText(value: Double(step.rawValue)))
                .padding(.leading, 6)
            Spacer()
            if step != .done {
                Button(tr("Überspringen")) { finish() }
                    .buttonStyle(.labelWerkPlain)
                    .help(tr("Assistent beenden – alles lässt sich später einrichten"))
                    .transition(.opacity)
            }
        }
        .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: step)
    }

    private var bottomBar: some View {
        HStack(spacing: 16) {
            Button {
                goBack()
            } label: {
                Label(tr("Zurück"), systemImage: "chevron.left")
            }
            .buttonStyle(.labelWerkSecondary)
            .opacity(step.previous == nil ? 0 : 1)
            .disabled(step.previous == nil)
            .help(tr("Zurück (←)"))

            Spacer(minLength: 8)

            progressDots

            Spacer(minLength: 8)

            Button {
                goNext()
            } label: {
                HStack(spacing: 6) {
                    Text(primaryTitle)
                        .contentTransition(.opacity)
                    Image(systemName: step == .done ? "arrow.right.circle.fill" : "chevron.right")
                        .contentTransition(.symbolEffect(.replace))
                }
                .padding(.horizontal, 6)
            }
            .buttonStyle(.labelWerkPrimary)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .help(step == .done ? tr("Assistent abschließen (↩)") : tr("Weiter (→ oder ↩)"))
        }
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: step)
    }

    private var progressDots: some View {
        HStack(spacing: 10) {
            ForEach(OnboardingStep.allCases) { item in
                Button {
                    go(to: item)
                } label: {
                    ZStack {
                        if item == step {
                            Capsule()
                                .fill(Theme.brandGradient)
                                .frame(width: 34, height: 10)
                                .overlay(Capsule().strokeBorder(Color.white.opacity(0.5), lineWidth: 1))
                                .shadow(color: Theme.violet.opacity(0.5), radius: 5)
                                .matchedGeometryEffect(id: "onboardingActiveDot", in: namespace)
                        } else {
                            Circle()
                                .fill(Color.primary.opacity(visited.contains(item) ? 0.45 : 0.18))
                                .frame(width: 9, height: 9)
                        }
                    }
                    .frame(height: 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.title)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(item == step ? .isSelected : [])
            }
        }
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: return tr("Los geht’s")
        case .driver: return DriverInstaller.shared.isInstalled ? tr("Weiter") : tr("Später installieren")
        case .printers: return model.sessions.isEmpty ? tr("Ohne Drucker weiter") : tr("Weiter")
        case .notifications: return tr("Weiter")
        case .done: return tr("LabelWerk starten")
        }
    }

    /// Unsichtbare Knöpfe für die Pfeiltasten (funktionieren ohne Fokus im ganzen Fenster).
    private var keyboardShortcuts: some View {
        ZStack {
            Button(action: goBack) { Color.clear.frame(width: 1, height: 1) }
                .buttonStyle(.plain)
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button(action: goNext) { Color.clear.frame(width: 1, height: 1) }
                .buttonStyle(.plain)
                .keyboardShortcut(.rightArrow, modifiers: [])
        }
        .frame(width: 1, height: 1)
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: Navigation

    private func goNext() {
        if let next = step.next {
            go(to: next)
        } else {
            finish()
        }
    }

    private func goBack() {
        if let previous = step.previous { go(to: previous) }
    }

    private func go(to target: OnboardingStep) {
        guard target != step else { return }
        // Erst die Richtung setzen (die alte Seite übernimmt ihren Abgang), dann die Seite wechseln.
        forward = target.rawValue > step.rawValue
        DispatchQueue.main.async {
            withAnimation(Motion.animation(.spring(response: 0.55, dampingFraction: 0.86), reduceMotion: reduceMotion)) {
                step = target
                visited.insert(target)
            }
        }
    }

    private func finish() {
        model.hasCompletedOnboarding = true
        model.isOnboardingPresented = false
        // Mitteilungen erst nach dem Assistenten einrichten (Delegate + ggf. Systemabfrage), damit
        // die Abfrage nicht schon beim ersten Start über dem Assistenten erscheint – auch bei
        // „Überspringen“. Wiederholte Aufrufe sind unschädlich (macOS fragt nur einmal).
        NotificationService.shared.setUp()
        dismiss()
    }
}

/// Seitenübergang: seitlicher Versatz, Unschärfe, Deckkraft und leichte Skalierung.
struct OnboardingPageEffect: ViewModifier {
    let offset: CGFloat
    let blur: CGFloat
    let opacity: Double
    let scale: CGFloat

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .blur(radius: blur)
            .opacity(opacity)
            .scaleEffect(scale)
    }
}
