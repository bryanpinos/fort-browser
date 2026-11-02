# Feedback draft: WKWebView ignores the client identity on a relay hop

File in **Feedback Assistant** → *iOS & iPadOS* → *Safari and Web Technologies* (WebKit).
Attach this folder zipped (without `server/certs/` and `build/`) and the
screenshot/log from step 6.

---

**Title:** WKWebView doesn't present the client certificate set on a relay hop (ProxyConfiguration relayHops); URLSession does

**Area:** WebKit, `WKWebsiteDataStore.proxyConfigurations`, Network framework relays

**Type:** Incorrect/Unexpected Behavior

**Summary**
A `ProxyConfiguration(relayHops:)` whose hop has a client identity
(`RelayHop(..., tlsOptions:)` with `sec_protocol_options_set_local_identity`)
works with `URLSession` (`URLSessionConfiguration.proxyConfigurations`): the
client certificate is sent to the relay and the request succeeds. The
identical configuration assigned to `WKWebsiteDataStore.proxyConfigurations`
never sends the certificate. The load fails with
`NSURLErrorDomain -1206` "The server "www.apple.com" requires a client
certificate", which names the destination site, not the relay, and
`WKNavigationDelegate webView(_:didReceive:completionHandler:)` is never
called, so the app can't supply the identity either.

**Scope (not the managed relay)**
This is the *per-app* relay a WKWebView gets from
`WKWebsiteDataStore.proxyConfigurations`, not a system relay from a
`com.apple.relay.managed` profile (`PayloadCertificateUUID`) or
`NERelayManager` (`identityData`). Those are system-wide, need MDM or a
NetworkExtension entitlement, and can't be scoped to one app's web view
without MDM. The point of the per-app API is a single app (e.g. a kids'
browser) pinning only its own web traffic, so it should support the same
client authentication that URLSession already supports with this exact
configuration. Also ruled out: HTTP/3 (only an HTTP/2 hop is configured and
the relay is HTTP/2-only), late or post-handshake certificate requests (Envoy
sends CertificateRequest in the initial TLS 1.3 handshake), and the advertised
CA list (URLSession succeeds against the same relay and CA).

**Steps to reproduce**
1. `brew install envoy xcodegen`
2. `./server/make-certs.sh` (creates a test server CA, a "localhost" relay cert, a client CA and `client.p12`, and copies `client.p12` into the app)
3. Trust the server CA in the simulator: `xcrun simctl keychain booted add-root-cert server/certs/ca.pem`
4. Start the relay, which requires a client cert: `cd server && envoy -c envoy.yaml`
5. `xcodegen generate`, then build and run *RelayClientCertRepro* on an iOS simulator (or launch with `-autorun YES`)
6. Tap **1. Load with URLSession**, then **2. Load with WKWebView**, and watch Envoy's output

**Expected**
Both loads succeed and Envoy logs `ACCESS peer=[CN=Repro Client] www.apple.com:443 200` twice.

**Actual**
- URLSession: `HTTP 200`; Envoy: `ACCESS peer=[CN=Repro Client] www.apple.com:443 200`
- WKWebView: `failed NSURLErrorDomain -1206 The server "www.apple.com" requires a client certificate.`; Envoy's `listener.127.0.0.1_8443.ssl.fail_verify_no_cert` increases (handshakes without a certificate); no challenge reaches the navigation delegate.

**Also tried (same result in WKWebView)**
- Storing the identity in the app's keychain (`SecItemAdd`) and using the keychain-backed `SecIdentity`.
- Answering `NSURLAuthenticationMethodClientCertificate` in `webView(_:didReceive:completionHandler:)`: never called.

**Environment**
Xcode 27.2 (27B52), iOS 27.2 simulator (iPad Pro 13-inch (M5)), macOS 27.0. Relay: Envoy 1.40.2, HTTP/2 CONNECT.

**Impact**
Apps that pin a WKWebView to a relay (e.g. a parental-control browser using a
parent-run relay) can't use mutual TLS for the relay. The workaround is an
in-app loopback CONNECT proxy that re-opens each tunnel with Network
framework, which adds complexity and an extra hop for every connection.

**Request**
Either honor the hop's `tlsOptions` local identity in WebKit's networking
process, or deliver the relay's client-certificate challenge to the
`WKNavigationDelegate` with `protectionSpace.isProxy() == true`.
