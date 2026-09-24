import SwiftUI
import SwiftData

@main
struct TokenBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let container: ModelContainer
    /// Instalação nova: abre a tela de primeiro uso.
    private let showOnboarding: Bool
    @State private var store: UsageStore
    @State private var navigation = AppNavigation()
    @State private var loginItem = LoginItemManager()
    @State private var localSources: LocalSources
    @State private var remoteSources: RemoteSourcesManager
    @State private var analytics: AnalyticsStore
    @State private var tips: TipsStore
    @State private var planUsage: ClaudePlanUsage
    @State private var priceUpdater: PriceUpdater
    @State private var proxy: LocalProxyManager

    init() {
        let container = Persistence.makeContainer()
        self.container = container
        showOnboarding = Onboarding.shouldPresent(container: container)
        let store = UsageStore(container: container)
        _store = State(initialValue: store)

        let planUsage = ClaudePlanUsage()
        store.planUsage = planUsage
        planUsage.onUpdate = { [weak store] in store?.refresh() }
        _planUsage = State(initialValue: planUsage)
        _tips = State(initialValue: TipsStore(container: container, store: store))
        _analytics = State(initialValue: AnalyticsStore(container: container))

        let localSources = LocalSources(container: container)
        localSources.codex.onPlanLimitsChange = { [weak store] in store?.refresh() }
        store.localSources = localSources
        _localSources = State(initialValue: localSources)

        let remoteSources = RemoteSourcesManager(container: container)
        store.remoteSources = remoteSources
        remoteSources.onCreditsChange = { [weak store] in store?.refresh() }
        _remoteSources = State(initialValue: remoteSources)

        let priceUpdater = PriceUpdater()
        _priceUpdater = State(initialValue: priceUpdater)

        let proxy = LocalProxyManager(container: container)
        _proxy = State(initialValue: proxy)

        // Em testes o app só serve de host: não lê logs, APIs nem o plano.
        if AppEnvironment.isRunningTests { return }
        #if DEBUG
        if DemoMode.isEnabled {
            DemoMode.seed(container: container, planUsage: planUsage, localSources: localSources)
            return
        }
        #endif
        planUsage.start()
        localSources.start()
        remoteSources.start()
        // Preços novos: relê os logs locais para recalcular os custos.
        priceUpdater.onChange = { table in localSources.all.forEach { $0.reprice(table) } }
        priceUpdater.start()
        GlobalHotKey.shared.start()
        proxy.start()
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
                .environment(priceUpdater)
                .environment(proxy)
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
                .environment(priceUpdater)
                .environment(proxy)
        }
        .modelContainer(container)
        .defaultSize(width: DemoMode.isEnabled ? 1180 : 960, height: DemoMode.isEnabled ? 880 : 640)
        .windowToolbarStyle(.unified)
        .defaultLaunchBehavior(DemoMode.isEnabled ? .presented : .suppressed)
        .restorationBehavior(.disabled)

        // Primeiro uso (só em instalação nova).
        Window("Boas-vindas ao TokenBar", id: Onboarding.windowID) {
            OnboardingView()
                .environment(localSources)
                .environment(planUsage)
                .environment(loginItem)
                .environment(navigation)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(showOnboarding ? .presented : .suppressed)
        .restorationBehavior(.disabled)

        // Prévia do popover numa janela, só para capturas no modo de demonstração.
        Window("TokenBar — popover", id: DemoMode.popoverWindowID) {
            OverviewPopover()
                .environment(store)
                .environment(navigation)
                .environment(localSources)
                .environment(remoteSources)
                .environment(tips)
                .environment(planUsage)
                .environment(priceUpdater)
                .environment(proxy)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(DemoMode.isEnabled ? .presented : .suppressed)
        .restorationBehavior(.disabled)
    }
}

enum WindowID {
    static let dashboard = "dashboard"
}
