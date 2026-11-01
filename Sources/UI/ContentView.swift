import SwiftUI

struct ContentView: View {
    @Environment(ConfigStore.self) private var store
    @Environment(NetworkGate.self) private var gate
    @Environment(ActivityLogger.self) private var logger

    @State private var model = BrowserModel()
    @State private var showPIN = false
    @State private var showSettings = false
    @FocusState private var urlFocused: Bool

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                addressBar
                if model.isLoading {
                    ProgressView(value: model.progress).progressViewStyle(.linear)
                }
                ZStack {
                    BrowserView(model: model, config: store.config, logger: logger)
                    if let message = model.blockedMessage {
                        blockedBanner(message)
                    }
                }
            }
            .disabled(!gate.isAllowed)
            .blur(radius: gate.isAllowed ? 0 : 6)

            if !gate.isAllowed {
                GateOverlay()
            }
        }
        .sheet(isPresented: $showPIN) {
            PINPromptView { ok in
                showPIN = false
                if ok { showSettings = true }
            }
        }
        .sheet(isPresented: $showSettings) {
            ParentSettingsView()
        }
        .onChange(of: store.config) { _, newValue in
            gate.apply(config: newValue)
            logger.apply(endpoint: newValue.logEndpoint)
        }
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

            Button { model.isLoading ? model.stop() : model.reload() } label: {
                Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise")
            }

            Button {
                if store.config.parentPINHash == nil { showSettings = true } else { showPIN = true }
            } label: { Image(systemName: "gearshape") }
                .accessibilityLabel("Parent settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
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

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "house.lodge")
                .font(.system(size: 72))
            Text("Hearth works from home")
                .font(.title.bold())
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 40)

            Button {
                if let url = URL(string: "tailscale://") { openURL(url) }
            } label: {
                Label("Open Tailscale", systemImage: "network")
            }
            .buttonStyle(.borderedProminent)

            Button("Check again") { gate.checkNow() }
                .buttonStyle(.bordered)

            if let checked = gate.lastChecked {
                Text("Last checked \(checked.formatted(date: .omitted, time: .shortened))")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }

    private var message: String {
        switch gate.state {
        case .checking: return "Checking the connection to home…"
        case .disconnected(let reason): return reason + ". Turn on the VPN and try again."
        default: return ""
        }
    }
}
