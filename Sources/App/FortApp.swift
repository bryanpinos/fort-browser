import SwiftUI

@main
struct FortApp: App {
    @State private var store: ConfigStore
    @State private var gate: NetworkGate
    @State private var logger: ActivityLogger
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
                .onAppear { gate.start() }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active: gate.start()
                    case .background:
                        gate.stop()
                        Task { await logger.flush() }
                    default: break
                    }
                }
        }
    }
}
