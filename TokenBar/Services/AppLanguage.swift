import AppKit

/// Idioma da interface, independente do idioma do macOS. Usa a mesma preferência que
/// Ajustes do Sistema → Idioma e Região → Aplicativos (AppleLanguages do app); vale ao reiniciar.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, portuguese, english

    var id: String { rawValue }

    var code: String? {
        switch self {
        case .system: nil
        case .portuguese: "pt-BR"
        case .english: "en"
        }
    }

    /// Nome de cada idioma na própria língua, como o macOS mostra.
    var title: String {
        switch self {
        case .system: String(localized: "Sistema")
        case .portuguese: "Português"
        case .english: "English"
        }
    }

    /// Escolha salva para o app (nil = segue o sistema).
    static var current: AppLanguage {
        let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
        let codes = domain?["AppleLanguages"] as? [String] ?? []
        return allCases.first { $0.code != nil && $0.code == codes.first } ?? .system
    }

    /// Idioma em uso agora (o que o app carregou ao abrir).
    static var active: String { Bundle.main.preferredLocalizations.first ?? "pt-BR" }

    func apply() {
        if let code {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }

    /// Reabre o app para carregar o idioma novo.
    @MainActor
    static func relaunch() {
        let path = Bundle.main.bundleURL.path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}
