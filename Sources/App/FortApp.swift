import SwiftUI

@main
struct FortApp: App {
    @State private var store: ConfigStore
    @State private var gate: NetworkGate
    @State private var logger: ActivityLogger
    @State private var forwarder = RelayForwarder()
    @State private var identities: ClientIdentityStore
    @State private var tabs: TabsModel
    @State private var favorites = FavoritesStore()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let store = ConfigStore()
        _store = State(initialValue: store)
        let identities = ClientIdentityStore()
        _identities = State(initialValue: identities)
        _gate = State(initialValue: NetworkGate(config: store.config, identities: identities))
        let logger = ActivityLogger(endpoint: store.config.logEndpoint)
        logger.deviceName = store.deviceName
        _logger = State(initialValue: logger)
        let gate = _gate.wrappedValue
        _tabs = State(initialValue: TabsModel(config: store.config, logger: logger,
                                              homeReachable: { gate.state == .connected }))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(gate)
                .environment(logger)
                .environment(forwarder)
                .environment(identities)
                .environment(tabs)
                .environment(favorites)
                .onAppear {
                    forwarder.apply(store.config, identities: identities)
                    gate.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        forwarder.ensureListening()
                        gate.start()
                    case .background:
                        gate.stop()
                        Task { await logger.flush() }
                    default: break
                    }
                }
        }
    }
}
