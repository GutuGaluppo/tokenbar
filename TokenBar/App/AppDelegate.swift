import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Sem ícone no Dock: o app vive na barra de menus (LSUIElement também está ligado no Info.plist).
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Fechar a última janela nunca encerra o app. Sair só pelo menu "Encerrar TokenBar".
        false
    }
}

extension NSApplication {
    /// Traz o app para frente. Necessário porque apps `.accessory` não se ativam sozinhos ao abrir janelas.
    @MainActor
    func bringToFront(showInDock: Bool) {
        if showInDock {
            setActivationPolicy(.regular)
        }
        activate()
        for window in windows where window.identifier?.rawValue.hasPrefix(WindowID.dashboard) == true {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
