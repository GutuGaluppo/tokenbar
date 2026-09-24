import SwiftUI

struct MenuBarLabel: View {
    let store: UsageStore
    @AppStorage(PreferenceKey.menuBarDisplay) private var display: MenuBarDisplay = .tokensToday
    @AppStorage(PreferenceKey.showDockIconWhenWindowOpen) private var showDockIcon = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let nearest = store.nearestLimit
        HStack(spacing: 4) {
            // Aviso quando o limite mostrado na barra passa de 80% (os demais aparecem no popover).
            let warning = (display.warningLimit(in: store.limits)?.fraction ?? 0) >= MenuBarDisplay.warningThreshold
            Image(systemName: warning ? "exclamationmark.triangle.fill" : "gauge.with.needle")
            switch display {
            case .iconOnly:
                EmptyView()
            case .tokensToday:
                Text(TokenFormat.compact(store.today.tokens)).monospacedDigit()
            case .costToday:
                Text(TokenFormat.usd(store.today.costUSD)).monospacedDigit()
            case .nearestLimit, .nearestLimitUsed:
                // Sem limite definido não há porcentagem a mostrar: "—%" deixa isso claro.
                if let nearest {
                    let value = display == .nearestLimit ? nearest.remainingFraction : nearest.fraction
                    Text(value.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
                } else {
                    Text("—%")
                }
            case .planSessionUsed, .planSessionRemaining:
                if let session = store.planSession {
                    let value = display == .planSessionUsed ? session.fraction : session.remainingFraction
                    Text(value.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
                } else {
                    Text("—%")
                }
            }
        }
        .accessibilityLabel("TokenBar: \(TokenFormat.compact(store.today.tokens)) tokens hoje")
        .task {
            // O rótulo da barra existe o tempo todo: daqui o atalho global consegue abrir o painel.
            GlobalHotKey.shared.action = {
                openWindow(id: WindowID.dashboard)
                NSApp.bringToFront(showInDock: showDockIcon)
            }
        }
    }
}
