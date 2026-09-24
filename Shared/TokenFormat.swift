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
}
