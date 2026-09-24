import AppKit
import Carbon.HIToolbox
import os

/// Atalho global ⌥⌘T que abre o painel, de qualquer app. Usa a API de hot keys do sistema
/// (não exige permissão de Acessibilidade). Desligado por padrão.
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()
    static let enabledKey = "hotkey.enabled"
    static let displayName = "⌥⌘T"

    /// Definido pela interface (precisa do `openWindow` do SwiftUI).
    var action: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var observer: NSObjectProtocol?
    private static let log = Logger(subsystem: "dev.galuppo.TokenBar", category: "HotKey")

    private init() {}

    func start() {
        guard !AppEnvironment.isIsolated else { return }
        apply()
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { GlobalHotKey.shared.apply() }
        }
    }

    private func apply() {
        let enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        if enabled && hotKeyRef == nil { register() }
        if !enabled && hotKeyRef != nil { unregister() }
    }

    private func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotKey.shared.action?() } }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec, nil, &handlerRef)
        let id = EventHotKeyID(signature: OSType(0x544B_4252), id: 1)   // "TKBR"
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_T), UInt32(optionKey | cmdKey), id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        Self.log.notice("Atalho \(Self.displayName, privacy: .public) registrado: \(status == noErr ? "ok" : "erro \(status)", privacy: .public)")
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }
}
