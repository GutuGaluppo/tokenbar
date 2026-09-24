import SwiftUI
import SwiftData

@main
struct TokenBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let container: ModelContainer
    @State private var store: UsageStore
    @State private var navigation = AppNavigation()
    @State private var loginItem = LoginItemManager()
    @State private var localSources: LocalSources
    @State private var remoteSources: RemoteSourcesManager
    @State private var analytics: AnalyticsStore
    @State private var tips: TipsStore
    @State private var planUsage: ClaudePlanUsage

    init() {
        let container = Persistence.makeContainer()
        self.container = container
        let store = UsageStore(container: container)
        _store = State(initialValue: store)

        let planUsage = ClaudePlanUsage()
        store.planUsage = planUsage
        planUsage.onUpdate = { [weak store] in store?.refresh() }
        planUsage.start()
        _planUsage = State(initialValue: planUsage)
        _tips = State(initialValue: TipsStore(container: container, store: store))
        _analytics = State(initialValue: AnalyticsStore(container: container))

        let localSources = LocalSources(container: container)
        localSources.codex.onPlanLimitsChange = { [weak store] in store?.refresh() }
        store.localSources = localSources
        localSources.start()
        _localSources = State(initialValue: localSources)

        let remoteSources = RemoteSourcesManager(container: container)
        remoteSources.start()
        _remoteSources = State(initialValue: remoteSources)
    }

    var body: some Scene {
        // Ícone permanente na barra de menus. O app continua vivo mesmo sem janelas abertas.
        MenuBarExtra {
            OverviewPopover()
                .environment(store)
                .environment(navigation)
                .environment(localSources)
                .environment(remoteSources)
                .environment(tips)
                .environment(planUsage)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        // Painel principal. Fechar (botão vermelho) só fecha a janela; o app segue na barra de menus.
        Window("TokenBar", id: WindowID.dashboard) {
            DashboardWindow()
                .environment(store)
                .environment(analytics)
                .environment(navigation)
                .environment(loginItem)
                .environment(localSources)
                .environment(remoteSources)
                .environment(tips)
                .environment(planUsage)
        }
        .modelContainer(container)
        .defaultSize(width: 960, height: 640)
        .windowToolbarStyle(.unified)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

enum WindowID {
    static let dashboard = "dashboard"
}
