import SwiftUI

struct MenuBarLabel: View {
    let store: UsageStore
    @AppStorage(PreferenceKey.menuBarDisplay) private var display: MenuBarDisplay = .tokensToday

    var body: some View {
        let nearest = store.nearestLimit
        HStack(spacing: 4) {
            // Em alerta (≥ 80% de algum limite) o ícone vira um aviso, visível em qualquer modo.
            Image(systemName: (nearest?.fraction ?? 0) >= 0.8 ? "exclamationmark.triangle.fill" : "gauge.with.needle")
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
    }
}
