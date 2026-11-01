import SwiftUI

@main
struct HearthApp: App {
    @State private var store: ConfigStore
    @State private var gate: NetworkGate
    @State private var logger: ActivityLogger
    @State private var forwarder = RelayForwarder()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let store = ConfigStore()
        _store = State(initialValue: store)
        _gate = State(initialValue: NetworkGate(config: store.config))
        let logger = ActivityLogger(endpoint: store.config.logEndpoint)
        logger.deviceName = store.deviceName
        _logger = State(initialValue: logger)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(gate)
                .environment(logger)
                .environment(forwarder)
                .onAppear {
                    forwarder.apply(store.config)
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
