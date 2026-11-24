import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// PIN-protected configuration screen. Everything here round-trips through
/// `GateConfig` JSON so a parent can also just paste a config exported from
/// another device or hosted on the NAS.
struct ParentSettingsView: View {
    @Environment(ConfigStore.self) private var store
    @Environment(NetworkGate.self) private var gate
    @Environment(ActivityLogger.self) private var logger
    @Environment(ClientIdentityStore.self) private var identities
    @Environment(\.dismiss) private var dismiss

    @State private var draft: GateConfig = .default
    @State private var probeText = ""
    @State private var proxyEnabled = false
    @State private var proxyKind: GateConfig.ProxyConfig.Kind = .socks5
    @State private var proxyHost = ""
    @State private var proxyPort = "1080"
    @State private var proxyToken = ""
    @State private var reviewPages = false
    @State private var engineChoice: EngineChoice = .google
    @State private var customEngineText = ""
    @State private var appLinksText = ""
    @State private var favoritesText = ""
    @State private var dataMessage: String?
    @State private var confirmClearAll = false
    @State private var showCertImporter = false
    @State private var pendingCertData: Data?
    @State private var certPassword = ""
    @State private var certMessage: String?
    @State private var allowText = ""
    @State private var denyText = ""
    @State private var homeText = ""
    @State private var logText = ""
    @State private var deviceNameText = ""
    @State private var newPIN = ""
    @State private var importText = ""
    @State private var importURLText = ""
    @State private var importError: String?
    @State private var showLog = false
    /// nil until checked, or when iOS can't say (older iOS, rate-limited).
    @State private var isDefaultBrowser: Bool?

    /// Set when a .p12 was opened in Fort from another app; consumed on appear.
    @Binding var incomingCertificate: Data?

    init(incomingCertificate: Binding<Data?> = .constant(nil)) {
        _incomingCertificate = incomingCertificate
    }

    var body: some View {
        NavigationStack {
            Form {
                if !store.isManaged && !store.managedFromHome.isEmpty {
                    Section {
                        Label("Some settings are managed from home: \(Self.homeLabels(store.managedFromHome)). Changes to them here won't stick.",
                              systemImage: "house.fill")
                    }
                }
                if store.isManaged {
                    Section {
                        Label("Configuration is managed by your MDM and can't be edited here.", systemImage: "lock.shield")
                    }
                }

                Section("Home network gate") {
                    TextField("Probe URL (leave empty to disable)", text: $probeText)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Stepper("Check every \(Int(draft.probeIntervalSeconds))s",
                            value: $draft.probeIntervalSeconds, in: 5...300, step: 5)
                    LabeledContent("Status", value: statusText)
                }

                Section("Proxy") {
                    Toggle("Pin all traffic through a proxy", isOn: $proxyEnabled)
                    if proxyEnabled {
                        Picker("Type", selection: $proxyKind) {
                            Text("Relay (recommended)").tag(GateConfig.ProxyConfig.Kind.relay)
                            Text("SOCKS5").tag(GateConfig.ProxyConfig.Kind.socks5)
                            Text("HTTP CONNECT").tag(GateConfig.ProxyConfig.Kind.http)
                        }
                        TextField(proxyKind == .relay ? "Host (e.g. relay.example.com)" : "Host (e.g. 100.101.102.103)",
                                  text: $proxyHost)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Port", text: $proxyPort).keyboardType(.numberPad)
                        if proxyKind == .relay {
                            SecureField("Relay token", text: $proxyToken)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                    }
                }
                .onChange(of: proxyKind) { _, kind in
                    if kind == .relay && proxyPort == "1080" { proxyPort = "8443" }
                }

                if proxyEnabled && proxyKind == .relay {
                    relayCertificateSection
                    Section {
                        Toggle("Send page text home for review", isOn: $reviewPages)
                    } header: { Text("Page review") } footer: {
                        Text("Fort sends each page's address, title and first 2,000 characters of text to your home relay, where your own AI model checks it and alerts you. Nothing is sent anywhere else.")
                    }
                }

                Section {
                    TextField("Allowed hosts, one per line (empty = allow all)", text: $allowText, axis: .vertical)
                        .lineLimit(3...8).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Blocked hosts, one per line", text: $denyText, axis: .vertical)
                        .lineLimit(3...8).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Toggle("Force strict safe search", isOn: $draft.enforceSafeSearch)
                    Picker("Search with", selection: $engineChoice) {
                        ForEach(EngineChoice.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    if engineChoice == .custom {
                        TextField("https://search.example.com/search?q=%s", text: $customEngineText)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Label("Fort can't force SafeSearch on a custom search engine. Pick one that filters results itself, or block adult sites at home.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.orange)
                        if !SearchEngine.isValidCustom(customEngineText.trimmingCharacters(in: .whitespaces)) {
                            Label("Use an https address with %s where the search words go. Until then, Fort searches with Google.",
                                  systemImage: "info.circle")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } header: { Text("Sites") } footer: {
                    Text("Subdomains match automatically. Blocked hosts win over allowed hosts.")
                }

                Section {
                    TextField("One per line: address, then a name\npbskids.org PBS Kids", text: $favoritesText, axis: .vertical)
                        .lineLimit(3...10).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("Favorites") } footer: {
                    Text("Shown on the start page of every iPad using these settings. Kids can add their own with the star.")
                }

                Section {
                    Button("Clear cache (keeps sign-ins)") { clearWebsiteData(all: false) }
                    Button("Clear all website data…", role: .destructive) { confirmClearAll = true }
                    if let dataMessage { Text(dataMessage).font(.footnote).foregroundStyle(.secondary) }
                } header: { Text("Website data") } footer: {
                    Text("Doesn't touch the activity log or anything sent home.")
                }
                .confirmationDialog("Clear all website data?", isPresented: $confirmClearAll, titleVisibility: .visible) {
                    Button("Clear everything", role: .destructive) { clearWebsiteData(all: true) }
                } message: {
                    Text("This signs Fort out of every site (school accounts, games). Saved favorites and settings stay.")
                }

                Section {
                    TextField("One per line, e.g. roblox", text: $appLinksText, axis: .vertical)
                        .lineLimit(2...6).textInputAutocapitalization(.never).autocorrectionDisabled()
                    let refused = AppLinksEditor.refused(appLinksText)
                    if !refused.isEmpty {
                        Label("Fort never opens \(refused.joined(separator: ", ")).", systemImage: "info.circle")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } header: { Text("Apps pages may open") } footer: {
                    Text("Some sites hand off to their app, like Roblox after signing in. Fort asks before opening one. It never opens other browsers, Shortcuts, Settings or the App Store.")
                }

                Section("General") {
                    TextField("Home page", text: $homeText)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Log endpoint (optional)", text: $logText)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("View local activity log") { showLog = true }
                }

                Section {
                    LabeledContent("Default browser", value: isDefaultBrowser.map { $0 ? "Fort" : "Not Fort" } ?? "Unknown")
                } footer: {
                    Text("With Fort as the default, links tapped in other apps open here, filtered. Choose it in Settings › Apps › Default Apps › Browser App.")
                }

                Section {
                    TextField("Device name (e.g. Ava's iPad)", text: $deviceNameText)
                        .autocorrectionDisabled()
                } header: { Text("This device") } footer: {
                    Text("Sent with activity logs so you can tell devices apart. Stays on this device: importing or exporting a config doesn't change it.")
                }

                Section("Parent PIN") {
                    SecureField(store.config.parentPINHash == nil ? "Set a PIN" : "New PIN (blank keeps current)", text: $newPIN)
                        .keyboardType(.numberPad)
                    if store.config.parentPINHash != nil {
                        Button("Remove PIN", role: .destructive) { store.set(pin: nil) }
                    }
                }

                Section("Import / export") {
                    TextField("Config URL (e.g. http://nas.tailnet/fort.json)", text: $importURLText)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Fetch config from URL") { fetchConfig() }
                        .disabled(importURLText.isEmpty)
                    TextField("Paste config JSON", text: $importText, axis: .vertical)
                        .lineLimit(3...10).font(.system(.footnote, design: .monospaced))
                    Button("Import pasted JSON") { importPasted() }
                        .disabled(importText.isEmpty)
                    ShareLink(item: store.exportJSON()) { Label("Export current config", systemImage: "square.and.arrow.up") }
                    if let importError {
                        Text(importError).foregroundStyle(.red).font(.footnote)
                    }
                }
            }
            .disabled(store.isManaged)
            .navigationTitle("Parent settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
            .sheet(isPresented: $showLog) { ActivityLogView() }
            .fileImporter(isPresented: $showCertImporter, allowedContentTypes: [.pkcs12]) { result in
                certMessage = nil
                switch result {
                case .success(let url):
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    if let data = try? Data(contentsOf: url) {
                        certPassword = ""
                        pendingCertData = data
                    } else {
                        certMessage = "Couldn't read that file."
                    }
                case .failure(let error):
                    certMessage = error.localizedDescription
                }
            }
            .alert("Certificate password", isPresented: Binding(
                get: { pendingCertData != nil },
                set: { if !$0 { pendingCertData = nil } })) {
                SecureField("Password", text: $certPassword)
                Button("Import") { importPendingCertificate() }
                Button("Cancel", role: .cancel) { pendingCertData = nil }
            } message: {
                Text("Enter the password you chose when the certificate was made.")
            }
            .onAppear {
                loadDraft()
                DeviceStatus.refreshDefaultBrowser()
                isDefaultBrowser = Self.checkDefaultBrowser()
                if let data = incomingCertificate {
                    incomingCertificate = nil
                    certPassword = ""
                    pendingCertData = data
                }
            }
        }
    }

    private var relayCertificateSection: some View {
        Section {
            if let info = identities.info {
                LabeledContent("Certificate", value: info.name)
                if let id = info.deviceID { LabeledContent("Device ID", value: id) }
                LabeledContent("Expires", value: info.expires.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "Unknown")
                Button("Replace certificate…") { showCertImporter = true }
                Button("Remove certificate", role: .destructive) {
                    identities.remove()
                    certMessage = "Certificate removed."
                }
            } else {
                Text("No certificate installed").foregroundStyle(.secondary)
                Button("Import certificate…") { showCertImporter = true }
            }
            if let certMessage {
                Text(certMessage).font(.footnote).foregroundStyle(.secondary)
            }
        } header: { Text("Relay certificate") } footer: {
            Text("A .p12 file made for this iPad. It's kept in this iPad's keychain only: never backed up, synced or included in exported settings. Takes effect immediately.")
        }
    }

    private func clearWebsiteData(all: Bool) {
        let types: Set<String> = all ? WKWebsiteDataStore.allWebsiteDataTypes() : [
            WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeFetchCache, WKWebsiteDataTypeOfflineWebApplicationCache,
        ]
        WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast) {
            dataMessage = all ? "All website data cleared. Sites will ask kids to sign in again." : "Cache cleared."
        }
    }

    private func importPendingCertificate() {
        guard let data = pendingCertData else { return }
        pendingCertData = nil
        do {
            let info = try identities.importPKCS12(data, password: certPassword)
            certMessage = "Imported \(info.deviceID ?? info.name)."
        } catch {
            certMessage = error.localizedDescription
        }
        certPassword = ""
    }

    private var statusText: String {
        switch gate.state {
        case .open: return "Gate disabled"
        case .checking: return "Checking…"
        case .connected: return "Connected to home"
        case .disconnected(let reason): return "Not connected: \(reason)"
        case .needsLocalNetwork: return "Blocked: allow Local Network for Fort in Settings"
        }
    }

    /// Plain names for the fields a home config can manage.
    static func homeLabels(_ keys: Set<String>) -> String {
        let names = ["favorites": "favorites", "denylist": "blocked sites", "allowlist": "allowed sites",
                     "enforceSafeSearch": "safe search", "searchEngine": "search engine", "appLinks": "app links",
                     "homeURL": "home page", "reviewPages": "page review",
                     "parentPINHash": "parent PIN", "logEndpoint": "log endpoint", "probeURL": "probe URL",
                     "probeIntervalSeconds": "check interval"]
        return keys.map { names[$0] ?? $0 }.sorted().joined(separator: ", ")
    }

    /// iOS rate-limits this check, so it's only made when settings open.
    private static func checkDefaultBrowser() -> Bool? {
        guard #available(iOS 18.2, *) else { return nil }
        return try? UIApplication.shared.isDefault(.webBrowser)
    }

    private func loadDraft() {
        draft = store.config
        probeText = draft.probeURL?.absoluteString ?? ""
        proxyEnabled = draft.proxy != nil
        proxyKind = draft.proxy?.kind ?? .socks5
        proxyHost = draft.proxy?.host ?? ""
        proxyPort = draft.proxy.map { String($0.port) } ?? "1080"
        proxyToken = draft.proxy?.authToken ?? ""
        reviewPages = draft.reviewPages ?? false
        let engine = SearchEngine(setting: draft.searchEngine)
        engineChoice = EngineChoice(engine)
        if case .custom(let template) = engine { customEngineText = template } else { customEngineText = "" }
        appLinksText = (draft.appLinks ?? []).joined(separator: "\n")
        favoritesText = FavoritesStore.format(draft.favorites)
        dataMessage = nil
        certMessage = nil
        allowText = draft.allowlist.joined(separator: "\n")
        denyText = draft.denylist.joined(separator: "\n")
        homeText = draft.homeURL.absoluteString
        logText = draft.logEndpoint?.absoluteString ?? ""
        deviceNameText = store.deviceName
        importText = ""
        importError = nil
    }

    private func save() {
        var cfg = draft
        cfg.probeURL = URL(string: probeText.trimmingCharacters(in: .whitespaces)).flatMap { $0.host == nil ? nil : $0 }
        cfg.proxy = proxyEnabled && !proxyHost.isEmpty
            ? GateConfig.ProxyConfig(kind: proxyKind, host: proxyHost.trimmingCharacters(in: .whitespaces),
                                     port: UInt16(proxyPort) ?? (proxyKind == .relay ? 8443 : 1080),
                                     authToken: proxyKind == .relay && !proxyToken.isEmpty ? proxyToken : nil)
            : nil
        cfg.reviewPages = proxyEnabled && proxyKind == .relay && reviewPages ? true : nil
        cfg.searchEngine = engineChoice.engine(custom: customEngineText).setting
        let apps = AppLinksEditor.parse(appLinksText)
        cfg.appLinks = apps.isEmpty ? nil : apps
        let parsedFavorites = FavoritesStore.parse(favoritesText)
        cfg.favorites = parsedFavorites.isEmpty ? nil : parsedFavorites
        cfg.allowlist = lines(allowText)
        cfg.denylist = lines(denyText)
        if let home = URL(string: homeText.trimmingCharacters(in: .whitespaces)), home.host != nil { cfg.homeURL = home }
        cfg.logEndpoint = URL(string: logText.trimmingCharacters(in: .whitespaces)).flatMap { $0.host == nil ? nil : $0 }
        cfg.parentPINHash = store.config.parentPINHash
        store.update(cfg)
        store.set(deviceName: deviceNameText)
        if !newPIN.isEmpty { store.set(pin: newPIN) }
        dismiss()
    }

    private func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    private func importPasted() {
        do {
            try store.importJSON(importText)
            loadDraft()
        } catch {
            importError = "Couldn't parse that JSON: \(error.localizedDescription)"
        }
    }

    private func fetchConfig() {
        guard let url = URL(string: importURLText.trimmingCharacters(in: .whitespaces)) else {
            importError = "That doesn't look like a URL"; return
        }
        Task {
            do {
                try await store.importFrom(url: url)
                loadDraft()
            } catch {
                importError = "Fetch failed: \(error.localizedDescription)"
            }
        }
    }
}

struct ActivityLogView: View {
    @Environment(ActivityLogger.self) private var logger
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(logger.entries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.url).font(.footnote).lineLimit(2)
                    HStack {
                        Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                        if !entry.allowed {
                            Text("blocked" + (entry.reason.map { " · \($0)" } ?? ""))
                                .foregroundStyle(.red)
                        }
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Activity")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .destructiveAction) { Button("Clear") { logger.clearLocal() } }
            }
        }
    }
}

/// The search-engine picker's choices; `.custom` takes its address from a text field.
enum EngineChoice: CaseIterable, Hashable {
    case google, bing, duckDuckGo, custom

    init(_ engine: SearchEngine) {
        switch engine {
        case .google: self = .google
        case .bing: self = .bing
        case .duckDuckGo: self = .duckDuckGo
        case .custom: self = .custom
        }
    }

    var label: String {
        switch self {
        case .google: return "Google"
        case .bing: return "Bing"
        case .duckDuckGo: return "DuckDuckGo"
        case .custom: return "Custom…"
        }
    }

    /// An invalid custom address saves as Google, the same as Fort would use anyway.
    func engine(custom: String) -> SearchEngine {
        switch self {
        case .google: return .google
        case .bing: return .bing
        case .duckDuckGo: return .duckDuckGo
        case .custom: return SearchEngine(setting: custom)
        }
    }
}

/// The "Apps pages may open" field: one scheme per line.
enum AppLinksEditor {
    /// Valid, allowed schemes in order, without duplicates.
    static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: \.isNewline).compactMap { AppLinks.normalize(String($0)) }
            .filter { !AppLinks.neverAllowed.contains($0) && seen.insert($0).inserted }
    }

    /// Entries Fort won't open: invalid, web, or never-allowed schemes.
    static func refused(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter {
            !$0.isEmpty && (AppLinks.normalize($0).map(AppLinks.neverAllowed.contains) ?? true)
        }
    }
}

