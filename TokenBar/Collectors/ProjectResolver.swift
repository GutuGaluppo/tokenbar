import Foundation

/// Nome do projeto a partir da pasta de trabalho: a raiz do repositório git que a contém.
/// Assim subpastas (ex.: `app/src-tauri`) e worktrees contam como o mesmo projeto.
/// Fora de um repositório, vale a própria pasta de trabalho.
enum ProjectResolver {
    /// Incrementar força a reimportação dos logs locais para regravar os projetos.
    static let version = 2

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String] = [:]

    static func project(for cwd: String) -> String {
        if let cached = lock.withLock({ cache[cwd] }) { return cached }
        let name = resolve(cwd)
        lock.withLock { cache[cwd] = name }
        return name
    }

    private static func resolve(_ cwd: String) -> String {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path()
        var url = URL(filePath: cwd, directoryHint: .isDirectory).standardizedFileURL

        // Sobe até achar um `.git`, sem considerar a própria pasta pessoal nem a raiz do disco.
        while url.pathComponents.count > 1, url.path() != home {
            let git = url.appending(path: ".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: git.path(), isDirectory: &isDirectory) {
                if !isDirectory.boolValue, let main = worktreeMainRepository(gitFile: git) {
                    return main
                }
                return url.lastPathComponent
            }
            url.deleteLastPathComponent()
        }
        // Pasta apagada, movida ou fora de um repositório: pula subpastas de nome genérico
        // (ex.: MAD/web → MAD, app/src-tauri → app, TrackZone/apps/web → TrackZone).
        let components = URL(filePath: cwd).pathComponents.filter { $0 != "/" }
        return components.last { !genericFolders.contains($0.lowercased()) } ?? components.last ?? cwd
    }

    /// Nomes de subpasta que quase nunca são o nome do projeto.
    private static let genericFolders: Set<String> = [
        "src", "src-tauri", "web", "app", "apps", "packages", "frontend", "backend",
        "server", "client", "api", "ios", "android", "macos", "desktop", "mobile", "docs",
    ]

    /// Worktree: `.git` é um arquivo "gitdir: /repo/.git/worktrees/<nome>" → nome de /repo.
    private static func worktreeMainRepository(gitFile: URL) -> String? {
        guard let text = try? String(contentsOf: gitFile, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") })
        else { return nil }
        let gitdir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard let range = gitdir.range(of: "/.git/worktrees/") else { return nil }
        return URL(filePath: String(gitdir[..<range.lowerBound])).lastPathComponent
    }
}
