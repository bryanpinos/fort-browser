import SwiftUI

@main
struct FortApp: App {
    @State private var store: ConfigStore
    @State private var gate: NetworkGate
    @State private var logger: ActivityLogger
    @State private var forwarder = RelayForwarder()
    @State private var identities: ClientIdentityStore
    /// Built once the scene is up, not in init: a WKWebView created before
    /// UIApplication is running crashes in UIKit's touch handling on the first scroll.
    @State private var tabs: TabsModel?
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
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let tabs {
                    ContentView().environment(tabs)
                } else {
                    Color.clear.onAppear {
                        let gate = gate
                        tabs = TabsModel(config: store.config, logger: logger,
                                         homeReachable: { gate.state == .connected },
                                         isBlockedAtHome: { await gate.isBlockedAtHome(host: $0) })
                    }
                }
            }
                .environment(store)
                .environment(gate)
                .environment(logger)
                .environment(forwarder)
                .environment(identities)
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
