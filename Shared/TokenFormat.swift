import Foundation

/// Formatação compartilhada entre o app e o widget.
enum TokenFormat {
    /// 950 → "950", 12_345 → "12,3k", 1_234_567 → "1,2M"
    static func compact(_ value: Int) -> String {
        let number = Double(value)
        let style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1))
        switch abs(number) {
        case 1_000_000_000...: return (number / 1_000_000_000).formatted(style) + "B"
        case 1_000_000...: return (number / 1_000_000).formatted(style) + "M"
        case 1_000...: return (number / 1_000).formatted(style) + "k"
        default: return value.formatted()
        }
    }

    static func usd(_ value: Double) -> String {
        value.formatted(.currency(code: "USD"))
    }

    /// Horário de um reinício: só a hora se for hoje, dia da semana + hora na próxima semana, data + hora depois.
    static func resetClockStyle(for date: Date, now: Date = .now, calendar: Calendar = .current) -> Date.FormatStyle {
        if calendar.isDate(date, inSameDayAs: now) { return .dateTime.hour().minute() }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        return days < 7 ? .dateTime.weekday(.abbreviated).hour().minute() : .dateTime.day().month(.abbreviated).hour().minute()
    }
}
