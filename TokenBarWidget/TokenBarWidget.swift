import WidgetKit
import SwiftUI

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: .now, snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(UsageEntry(date: .now, snapshot: context.isPreview ? .placeholder : WidgetSnapshot.load() ?? .placeholder))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        // O app pede recarga quando os números mudam; isto é só a rede de segurança.
        let entry = UsageEntry(date: .now, snapshot: WidgetSnapshot.load())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(15 * 60))))
    }
}

@main
struct TokenBarWidgetBundle: WidgetBundle {
    var body: some Widget {
        UsageWidget()
    }
}

struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshot.widgetKind, provider: UsageProvider()) { entry in
            UsageWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .environment(\.locale, entry.snapshot?.language.map(Locale.init(identifier:)) ?? .current)
        }
        .configurationDisplayName("TokenBar")
        .description("Quanto resta da sessão do plano e o consumo de hoje.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            switch family {
            case .systemMedium: medium(snapshot)
            default: small(snapshot)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "gauge.with.needle")
                    .font(.title)
                Text("Abra o TokenBar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func small(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let main = snapshot.limits.first {
                RemainingGauge(limit: main)
                    .frame(maxWidth: .infinity)
                Text(main.title)
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
                if let resetsAt = main.resetsAt {
                    Text(resetsAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            } else {
                Text("Hoje").font(.caption).foregroundStyle(.secondary)
                Text(TokenFormat.compact(snapshot.todayTokens))
                    .font(.system(.title, design: .rounded, weight: .semibold))
            }
            Spacer(minLength: 0)
            todayLine(snapshot)
                .frame(maxWidth: .infinity)
        }
    }

    private func medium(_ snapshot: WidgetSnapshot) -> some View {
        HStack(spacing: 14) {
            VStack(spacing: 6) {
                if let main = snapshot.limits.first {
                    RemainingGauge(limit: main)
                    Text(main.title).font(.caption.weight(.semibold))
                }
                Spacer(minLength: 0)
                todayLine(snapshot)
            }
            .frame(width: 110)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(snapshot.limits.dropFirst().prefix(3)) { limit in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(limit.title).font(.caption)
                            Spacer()
                            Text("restam \(limit.remaining.formatted(.percent.precision(.fractionLength(0))))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: min(limit.fraction, 1))
                            .tint(limitTint(limit.fraction))
                    }
                }
                if snapshot.limits.count <= 1 {
                    Text("Defina limites no TokenBar para vê-los aqui.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func todayLine(_ snapshot: WidgetSnapshot) -> some View {
        Text("Hoje \(TokenFormat.compact(snapshot.todayTokens)) · \(TokenFormat.usd(snapshot.todayCostUSD))")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

/// Anel com a porcentagem restante no centro.
struct RemainingGauge: View {
    let limit: WidgetSnapshot.Limit

    var body: some View {
        Gauge(value: min(limit.fraction, 1)) {
            EmptyView()
        } currentValueLabel: {
            VStack(spacing: -2) {
                Text(limit.remaining.formatted(.percent.precision(.fractionLength(0))))
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                Text("restam")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(limitTint(limit.fraction))
        .scaleEffect(1.35)
        .frame(height: 70)
    }
}

func limitTint(_ fraction: Double) -> Color {
    switch fraction {
    case 0.95...: .red
    case 0.8...: .orange
    default: .accentColor
    }
}
