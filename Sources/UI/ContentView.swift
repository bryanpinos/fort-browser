import SwiftUI

struct ContentView: View {
    @Environment(ConfigStore.self) private var store
    @Environment(NetworkGate.self) private var gate
    @Environment(ActivityLogger.self) private var logger
    @Environment(RelayForwarder.self) private var forwarder
    @Environment(ClientIdentityStore.self) private var identities

    @State private var model = BrowserModel()
    @State private var showPIN = false
    @State private var showSettings = false
    /// A .p12 opened in Fort (AirDrop / Files "Open in"), waiting for the
    /// parent to unlock settings and enter its password.
    @State private var incomingCertificate: Data?
    @FocusState private var urlFocused: Bool

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                addressBar
                if model.isLoading {
                    ProgressView(value: model.progress).progressViewStyle(.linear)
                }
                ZStack {
                    BrowserView(model: model, config: store.config, logger: logger, forwarder: forwarder, identities: identities, gate: gate)
                    if let message = model.blockedMessage {
                        blockedBanner(message)
                    }
                }
            }
            .disabled(!gate.isAllowed)
            .blur(radius: gate.isAllowed ? 0 : 6)

            if !gate.isAllowed {
                GateOverlay(openParentSettings: openParentSettings)
            }
        }
        .sheet(isPresented: $showPIN) {
            PINPromptView { ok in
                showPIN = false
                if ok { showSettings = true }
            }
        }
        .sheet(isPresented: $showSettings) {
            ParentSettingsView(incomingCertificate: $incomingCertificate)
        }
        .onChange(of: store.config) { _, newValue in
            gate.apply(config: newValue)
            logger.apply(endpoint: newValue.logEndpoint)
            syncLoggerUpload()
            forwarder.apply(newValue, identities: identities)
        }
        .onChange(of: identities.info) { _, _ in
            forwarder.apply(store.config, identities: identities)
            gate.apply(config: store.config)
            syncLoggerUpload()
        }
        .onAppear { syncLoggerUpload() }
        .onOpenURL { url in receiveCertificate(at: url) }
        .onChange(of: store.deviceName) { _, newValue in
            logger.deviceName = newValue
        }
    }

    private var addressBar: some View {
        HStack(spacing: 8) {
            Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!model.canGoBack)
            Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!model.canGoForward)
            Button { model.load(url: store.config.homeURL) } label: { Image(systemName: "house") }

            TextField("Search or enter a site", text: $model.urlText)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.webSearch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($urlFocused)
                .onSubmit {
                    model.load(text: model.urlText, homeURL: store.config.homeURL)
                    urlFocused = false
                }
                // Like Safari: tapping in selects the whole address, so typing
                // replaces it instead of appending to it.
                .onChange(of: urlFocused) { _, focused in
                    guard focused, !model.urlText.isEmpty else { return }
                    DispatchQueue.main.async {
                        UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
                    }
                }
                // Clear button while editing, like Safari's; keeps the keyboard up.
                .overlay(alignment: .trailing) {
                    if urlFocused && !model.urlText.isEmpty {
                        Button {
                            model.urlText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear address")
                    }
                }

            Button { model.isLoading ? model.stop() : model.reload() } label: {
                Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise")
            }

            Button(action: openParentSettings) { Image(systemName: "gearshape") }
                .accessibilityLabel("Parent settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// Reads a certificate handed to Fort by another app, deletes the copy iOS
    /// placed in our Inbox (so no key bundle lingers on disk), and routes it
    /// through the parent PIN to Parent settings.
    /// With a relay, activity (and page text, if enabled) goes to the relay's
    /// /fort/ingest using this device's certificate; otherwise to logEndpoint.
    private func syncLoggerUpload() {
        let config = store.config
        var ingest: ActivityLogger.Ingest?
        if let proxy = config.proxy, proxy.kind == .relay,
           let health = NetworkGate.relayHealthURL(for: proxy) {
            ingest = .init(url: health.deletingLastPathComponent().appendingPathComponent("ingest"), token: proxy.authToken)
        }
        let identities = identities
        logger.identityProvider = { identities.identity() }
        logger.apply(ingest: ingest, reviewPages: config.reviewPages ?? false)
    }

    /// Settings stay reachable even while the gate is closed (e.g. to fix
    /// the relay address); the PIN still protects them.
    private func openParentSettings() {
        if store.config.parentPINHash == nil { showSettings = true } else { showPIN = true }
    }

    private func receiveCertificate(at url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        let data = try? Data(contentsOf: url)
        if scoped { url.stopAccessingSecurityScopedResource() }
        if url.path.contains("/Inbox/") { try? FileManager.default.removeItem(at: url) }
        guard let data, !data.isEmpty else { return }
        incomingCertificate = data
        openParentSettings()
    }

    private func blockedBanner(_ message: String) -> some View {
        VStack {
            HStack {
                Image(systemName: "hand.raised.fill")
                Text(message)
                Spacer()
                Button("OK") { model.blockedMessage = nil }
            }
            .padding()
            .background(.yellow.opacity(0.9), in: RoundedRectangle(cornerRadius: 12))
            .padding()
            Spacer()
        }
    }
}

/// Full-screen "connect to home" screen shown whenever the probe fails.
struct GateOverlay: View {
    @Environment(NetworkGate.self) private var gate
    @Environment(\.openURL) private var openURL
    let openParentSettings: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "house.lodge")
                .font(.system(size: 72))
            Text("Fort works from home")
                .font(.title.bold())
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 40)

            if gate.state == .needsLocalNetwork {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } label: {
                    Label("Open Settings", systemImage: "gear")
                }
                .buttonStyle(.borderedProminent)
            } else if !gate.usesRelay {
                Button {
                    if let url = URL(string: "tailscale://") { openURL(url) }
                } label: {
                    Label("Open Tailscale", systemImage: "network")
                }
                .buttonStyle(.borderedProminent)
            }

            Button("Check again") { gate.checkNow() }
                .buttonStyle(.bordered)

            if let checked = gate.lastChecked {
                Text("Last checked \(checked.formatted(date: .omitted, time: .shortened))")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            Button(action: openParentSettings) {
                Label("Grown-ups", systemImage: "gearshape")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("gate-parent-settings")
            .padding()
        }
        .background(.regularMaterial)
    }

    private var message: String {
        switch gate.state {
        case .checking: return "Checking the connection to home…"
        case .needsLocalNetwork:
            return "Fort needs permission to reach home. Ask a grown-up to turn on Local Network for Fort in Settings."
        case .disconnected(let reason):
            return gate.usesRelay ? reason + ". Fort only works at home for now." : reason + ". Turn on the VPN and try again."
        default: return ""
        }
    }
}
