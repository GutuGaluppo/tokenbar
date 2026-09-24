import Foundation
import SwiftData
import os

enum Persistence {
    private static let log = Logger(subsystem: "dev.galuppo.TokenBar", category: "Persistence")

    /// `~/Library/Application Support/TokenBar`
    static var directory: URL {
        if AppEnvironment.isRunningTests {
            return FileManager.default.temporaryDirectory.appending(path: "TokenBar-Tests", directoryHint: .isDirectory)
        }
        #if DEBUG
        if DemoMode.isEnabled {
            return URL.applicationSupportDirectory.appending(path: "TokenBar-Demo", directoryHint: .isDirectory)
        }
        #endif
        return URL.applicationSupportDirectory.appending(path: "TokenBar", directoryHint: .isDirectory)
    }

    static var storeURL: URL {
        directory.appending(path: "TokenBar.store")
    }

    static func makeContainer() -> ModelContainer {
        if AppEnvironment.isRunningTests {
            // Testes nunca tocam o banco real.
            return try! ModelContainer(for: UsageEvent.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }
        if DemoMode.isEnabled {
            // A demonstração sempre começa de um banco limpo.
            try? FileManager.default.removeItem(at: directory)
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return try openContainer()
        } catch {
            // Esquema incompatível (ex.: banco de uma versão anterior). Os dados locais são reimportáveis
            // a partir dos logs, então guardamos o banco antigo de lado e começamos um novo.
            log.error("Falha ao abrir o banco, recriando: \(error.localizedDescription)")
            moveStoreAside()
            do {
                return try openContainer()
            } catch {
                fatalError("Não foi possível abrir o banco do TokenBar: \(error)")
            }
        }
    }

    private static func openContainer() throws -> ModelContainer {
        try ModelContainer(for: UsageEvent.self, configurations: ModelConfiguration(url: storeURL))
    }

    private static func moveStoreAside() {
        let stamp = Int(Date.now.timeIntervalSince1970)
        let fileManager = FileManager.default
        for suffix in ["", "-shm", "-wal"] {
            let url = URL(filePath: storeURL.path() + suffix)
            guard fileManager.fileExists(atPath: url.path()) else { continue }
            try? fileManager.moveItem(at: url, to: URL(filePath: url.path() + ".bak-\(stamp)"))
        }
        // Sem banco, os cursores de leitura dos logs precisam recomeçar do zero.
        LocalSources.resetAllCursors()
    }
}
