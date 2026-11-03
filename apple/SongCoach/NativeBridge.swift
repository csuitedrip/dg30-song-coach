import Foundation
import WebKit
import CoreMIDI
import MediaPlayer
import AuthenticationServices
#if os(iOS)
import UIKit
import AVFoundation
#else
import AppKit
#endif

/// Everything the web page asks of the app goes through here: MIDI (USB and Bluetooth pianos),
/// the Bluetooth MIDI pairing screen, the microphone, saving/sharing files and "now playing".
final class NativeBridge: NSObject, ObservableObject {

    static let siteURL = URL(string: "https://songcoach.csuitedrip.com/")!

    private(set) weak var webView: WKWebView?

    // MIDI state
    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var outPort = MIDIPortRef()
    private var midiReady = false
    private var openAll = false
    private var connectedSources = Set<MIDIEndpointRef>()
    private var lastDeviceIDs = Set<String>()

    // Bluetooth search started from the page ("Find my piano")

    override init() {
        super.init()
        setupMIDI()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    // MARK: - Web view

    func makeWebView() -> WKWebView {
        if let wv = webView { return wv }
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        #if os(iOS)
        cfg.allowsInlineMediaPlayback = true
        #endif
        let ucc = WKUserContentController()
        ucc.add(WeakScriptHandler(self), name: "sc")
        ucc.addUserScript(WKUserScript(source: Self.shim(initialDevices: deviceListJSON()),
                                       injectionTime: .atDocumentStart, forMainFrameOnly: true))
        cfg.userContentController = ucc

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.uiDelegate = self
        wv.navigationDelegate = self
        if #available(iOS 16.4, macOS 13.3, *) { wv.isInspectable = true }
        #if os(iOS)
        wv.scrollView.bounces = false
        wv.isOpaque = false
        wv.backgroundColor = .black
        #endif
        wv.load(URLRequest(url: Self.siteURL))
        webView = wv
        return wv
    }

    /// Defines window.SCNative before the page's own code runs, matching the Android app's bridge.
    static func shim(initialDevices: String) -> String {
        let initial = initialDevices.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
        #if os(iOS)
        let platform = "ios"
        #else
        let platform = "macos"
        #endif
        return """
        (function(){
          if (window.SCNative) return;
          var post = function(cmd, args){ try { window.webkit.messageHandlers.sc.postMessage({cmd: cmd, args: args || []}); } catch(e){} };
          window.__scDevList = '\(initial)';
          window.__scSetDevices = function(j){ window.__scDevList = j; };
          window.SCNative = {
            platform: function(){ return '\(platform)'; },
            version: function(){ return '\(version)'; },
            midiDevices: function(){ return window.__scDevList || '[]'; },
            midiOpenAll: function(){ post('midiOpenAll'); },
            midiSend: function(id, csv){ post('midiSend', [String(id), String(csv)]); },
            bleFind: function(filter, all){ post('bleFind', [String(filter || ''), !!all]); },
            bleConnect: function(addr){ post('bleConnect', [String(addr || '')]); },
            audioOut: function(){ return 'web'; },
            media: function(playing, title, sub){ post('media', [!!playing, String(title || ''), String(sub || '')]); },
            openExternal: function(url){ post('openExternal', [String(url)]); },
            saveFile: function(name, type, b64){ post('saveFile', [String(name), String(type), String(b64)]); },
            shareFile: function(name, type, b64, text){ post('shareFile', [String(name), String(type), String(b64), String(text || '')]); },
            shareText: function(t){ post('shareText', [String(t || '')]); }
          };
        })();
        """
    }

    private func js(_ code: String) {
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(code, completionHandler: nil)
        }
    }

    private static func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s], options: [])
        let arr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
    }

    func setHidden(_ hidden: Bool) {
        js("window.__scSetHidden && window.__scSetHidden(\(hidden ? "true" : "false"))")
    }

    // MARK: - Messages from the page

    fileprivate func handle(_ body: Any) {
        guard let msg = body as? [String: Any], let cmd = msg["cmd"] as? String else { return }
        let args = msg["args"] as? [Any] ?? []
        func s(_ i: Int) -> String { i < args.count ? (args[i] as? String ?? "\(args[i])") : "" }
        func b(_ i: Int) -> Bool { i < args.count ? (args[i] as? Bool ?? false) : false }

        switch cmd {
        case "midiOpenAll":
            openAll = true
            connectAllSources()
        case "midiSend":
            let bytes = s(1).split(separator: ",").compactMap { UInt8($0.trimmingCharacters(in: .whitespaces)) }
            send(to: s(0), bytes: bytes)
        case "bleFind":
            ble.find(filter: s(0), showAll: b(1))
        case "bleConnect":
            if s(0).hasPrefix("ble-") { ble.reconnect(id: s(0)) } else { reconnectCoreMIDI(id: s(0)) }
        case "media":
            updateNowPlaying(playing: b(0), title: s(1), subtitle: s(2))
        case "openExternal":
            guard let url = URL(string: s(0)) else { break }
            if url.query?.contains("applogin") == true { startGoogleLogin(url) } else { openURL(url) }
        case "saveFile":
            saveFile(name: s(0), base64: s(2), share: false, text: "")
        case "shareFile":
            saveFile(name: s(0), base64: s(2), share: true, text: s(3))
        case "shareText":
            shareText(s(0))
        default:
            break
        }
    }

    // MARK: - MIDI

    private func setupMIDI() {
        var status = MIDIClientCreateWithBlock("Song Coach" as CFString, &client) { [weak self] note in
            if note.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async { self?.midiSetupChanged() }
            }
        }
        guard status == noErr else { return }
        status = MIDIInputPortCreateWithBlock(client, "Song Coach In" as CFString, &inPort) { [weak self] list, srcRef in
            guard let self else { return }
            let src = MIDIEndpointRef(UInt(bitPattern: srcRef))
            let id = self.groupID(for: src)
            var all: [UInt8] = []
            for packet in list.unsafeSequence() {
                let len = Int(packet.pointee.length)
                let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \MIDIPacket.data) ?? 10
                let raw = UnsafeRawPointer(packet) + dataOffset
                all.append(contentsOf: UnsafeBufferPointer(start: raw.assumingMemoryBound(to: UInt8.self), count: len))
            }
            if all.isEmpty { return }
            let arr = all.map(String.init).joined(separator: ",")
            self.js("window.__scMidi && window.__scMidi(\(NativeBridge.jsString(id)), [\(arr)])")
        }
        guard status == noErr else { return }
        status = MIDIOutputPortCreate(client, "Song Coach Out" as CFString, &outPort)
        midiReady = status == noErr
        lastDeviceIDs = Set(currentDevices().map { $0.id })
    }

    private struct Dev { let id: String; let name: String; var input: Bool; var output: Bool }

    private func intProp(_ obj: MIDIObjectRef, _ prop: CFString) -> Int32? {
        var v: Int32 = 0
        return MIDIObjectGetIntegerProperty(obj, prop, &v) == noErr ? v : nil
    }

    private func stringProp(_ obj: MIDIObjectRef, _ prop: CFString) -> String? {
        var cf: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(obj, prop, &cf) == noErr, let s = cf?.takeRetainedValue() else { return nil }
        return s as String
    }

    /// One id per physical piano, shared by its input and output.
    private func groupID(for endpoint: MIDIEndpointRef) -> String {
        var entity = MIDIEntityRef()
        if MIDIEndpointGetEntity(endpoint, &entity) == noErr, entity != 0 {
            var device = MIDIDeviceRef()
            if MIDIEntityGetDevice(entity, &device) == noErr, device != 0, let u = intProp(device, kMIDIPropertyUniqueID) {
                return "dev\(u)"
            }
            if let u = intProp(entity, kMIDIPropertyUniqueID) { return "ent\(u)" }
        }
        return "ep\(intProp(endpoint, kMIDIPropertyUniqueID) ?? Int32(endpoint))"
    }

    private func usable(_ endpoint: MIDIEndpointRef) -> Bool {
        if (intProp(endpoint, kMIDIPropertyOffline) ?? 0) != 0 { return false }
        let name = displayName(endpoint).lowercased()
        return !(name.contains("network session") || name.hasPrefix("iac") || name.contains("session 1"))
    }

    private func displayName(_ endpoint: MIDIEndpointRef) -> String {
        stringProp(endpoint, kMIDIPropertyDisplayName) ?? stringProp(endpoint, kMIDIPropertyName) ?? "MIDI device"
    }

    private func currentDevices() -> [Dev] {
        var byID: [String: Dev] = [:]
        var order: [String] = []
        for i in 0..<MIDIGetNumberOfSources() {
            let e = MIDIGetSource(i); guard usable(e) else { continue }
            let id = groupID(for: e)
            if byID[id] == nil { byID[id] = Dev(id: id, name: displayName(e), input: true, output: false); order.append(id) }
            else { byID[id]?.input = true }
        }
        for i in 0..<MIDIGetNumberOfDestinations() {
            let e = MIDIGetDestination(i); guard usable(e) else { continue }
            let id = groupID(for: e)
            if byID[id] == nil { byID[id] = Dev(id: id, name: displayName(e), input: false, output: true); order.append(id) }
            else { byID[id]?.output = true }
        }
        var list = order.compactMap { byID[$0] }
        // Bluetooth pianos connected by this app
        for d in ble.devices where !list.contains(where: { $0.id == d.id }) {
            list.append(Dev(id: d.id, name: d.name, input: true, output: true))
        }
        return list
    }

    private func deviceListJSON() -> String {
        let arr = currentDevices().map { ["id": $0.id, "name": $0.name, "in": $0.input, "out": $0.output] as [String: Any] }
        let data = (try? JSONSerialization.data(withJSONObject: arr, options: [])) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func pushDeviceList() {
        js("window.__scSetDevices && window.__scSetDevices(\(NativeBridge.jsString(deviceListJSON()))); window.__scMidiChanged && window.__scMidiChanged();")
    }

    private func connectAllSources() {
        guard midiReady else { return }
        var present = Set<MIDIEndpointRef>()
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            guard usable(src) else { continue }
            present.insert(src)
            if !connectedSources.contains(src) {
                let refCon = UnsafeMutableRawPointer(bitPattern: UInt(src))
                if MIDIPortConnectSource(inPort, src, refCon) == noErr { connectedSources.insert(src) }
            }
        }
        connectedSources.formIntersection(present)
    }

    private func midiSetupChanged() {
        if openAll { connectAllSources() }
        let devices = currentDevices()
        let ids = Set(devices.map { $0.id })
        pushDeviceList()
        lastDeviceIDs = ids
    }

    private func send(to id: String, bytes: [UInt8]) {
        if id.hasPrefix("ble-") { ble.send(id: id, bytes: bytes); return }
        guard midiReady, !bytes.isEmpty else { return }
        for i in 0..<MIDIGetNumberOfDestinations() {
            let dest = MIDIGetDestination(i)
            guard groupID(for: dest) == id else { continue }
            let size = 1024 + bytes.count
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
            defer { buffer.deallocate() }
            let list = buffer.assumingMemoryBound(to: MIDIPacketList.self)
            let packet = MIDIPacketListInit(list)
            _ = MIDIPacketListAdd(list, size, packet, 0, bytes.count, bytes)
            MIDISend(outPort, dest, list)
        }
    }

    // MARK: - Bluetooth MIDI (CoreBluetooth; see BluetoothMIDI.swift)

    private lazy var ble: BluetoothMIDI = {
        let b = BluetoothMIDI()
        b.onStatus = { [weak self] state, name, id in
            self?.js("window.__scBle && window.__scBle(\(NativeBridge.jsString(state)), \(NativeBridge.jsString(name)), \(NativeBridge.jsString(id)))")
        }
        b.onMIDI = { [weak self] id, bytes in
            let arr = bytes.map(String.init).joined(separator: ",")
            self?.js("window.__scMidi && window.__scMidi(\(NativeBridge.jsString(id)), [\(arr)])")
        }
        b.onDevicesChanged = { [weak self] in self?.pushDeviceList() }
        b.choose = { [weak self] list, done in self?.chooseDevice(list, done) }
        return b
    }()

    /// A USB/network MIDI piano already known to CoreMIDI, used when the page asks to reconnect to a non-Bluetooth id.
    private func reconnectCoreMIDI(id: String) {
        if let dev = currentDevices().first(where: { $0.id == id }) {
            js("window.__scBle && window.__scBle('connected', \(NativeBridge.jsString(dev.name)), \(NativeBridge.jsString(dev.id)))")
        } else {
            js("window.__scBle && window.__scBle('quiet-fail', '', '')")
        }
    }

    #if os(iOS)
    private func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.sorted { a, _ in a.activationState == .foregroundActive }.flatMap { $0.windows }
        let window = windows.first { $0.isKeyWindow } ?? scenes.compactMap { $0.keyWindow }.first
            ?? webView?.window ?? windows.first { !$0.isHidden }
        var top = window?.rootViewController
        while let p = top?.presentedViewController { top = p }
        return top
    }

    private func chooseDevice(_ list: [(name: String, id: UUID)], _ done: @escaping (UUID?) -> Void) {
        guard let top = topController() else { return done(nil) }
        let sheet = UIAlertController(title: "Choose your piano", message: nil, preferredStyle: .actionSheet)
        for item in list {
            sheet.addAction(UIAlertAction(title: item.name, style: .default) { _ in done(item.id) })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in done(nil) })
        if let pop = sheet.popoverPresentationController, let v = webView {
            pop.sourceView = v
            pop.sourceRect = CGRect(x: v.bounds.midX, y: v.bounds.midY, width: 1, height: 1)
        }
        top.present(sheet, animated: true)
    }
    #else
    private func chooseDevice(_ list: [(name: String, id: UUID)], _ done: @escaping (UUID?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Choose your piano"
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        popup.addItems(withTitles: list.map { $0.name })
        alert.accessoryView = popup
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        done(alert.runModal() == .alertFirstButtonReturn ? list[popup.indexOfSelectedItem].id : nil)
    }
    #endif

    // MARK: - Now playing

    private func updateNowPlaying(playing: Bool, title: String, subtitle: String) {
        DispatchQueue.main.async {
            let center = MPNowPlayingInfoCenter.default()
            center.nowPlayingInfo = [MPMediaItemPropertyTitle: title.isEmpty ? "Song Coach" : title,
                                     MPMediaItemPropertyArtist: subtitle]
            #if os(macOS)
            center.playbackState = playing ? .playing : .paused
            #endif
        }
    }

    // MARK: - Google sign-in
    // The site's app sign-in (…?applogin) ends by sending the Google token to an Android-only
    // "intent://" link. Safari can't open that, so the app runs the sign-in in Apple's own sign-in
    // sheet and catches that link itself, then hands the token to the page.

    private var authSession: ASWebAuthenticationSession?

    private func startGoogleLogin(_ url: URL) {
        DispatchQueue.main.async {
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "intent") { [weak self] callback, _ in
                guard let self else { return }
                self.authSession = nil
                guard let callback else { return } // cancelled
                let text = callback.absoluteString
                guard let r = text.range(of: "S.token=") else { return }
                var token = String(text[r.upperBound...])
                if let end = token.firstIndex(of: ";") { token = String(token[..<end]) }
                token = token.removingPercentEncoding ?? token
                self.js("window.__scGoogle && window.__scGoogle(\(NativeBridge.jsString(token)))")
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true // no Google account left behind in Safari
            self.authSession = session
            session.start()
        }
    }

    // MARK: - Links, files, sharing

    private func openURL(_ url: URL) {
        DispatchQueue.main.async {
            #if os(iOS)
            UIApplication.shared.open(url)
            #else
            NSWorkspace.shared.open(url)
            #endif
        }
    }

    private func safeName(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = name.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Song Coach file" : cleaned
    }

    private func saveFile(name: String, base64: String, share: Bool, text: String) {
        guard let data = Data(base64Encoded: base64) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safeName(name))
        try? data.write(to: url, options: .atomic)
        DispatchQueue.main.async {
            #if os(iOS)
            var items: [Any] = [url]
            if share, !text.isEmpty { items.append(text) }
            self.presentShare(items)
            #else
            if share {
                self.macShare([url])
            } else {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = url.lastPathComponent
                panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                if panel.runModal() == .OK, let dest = panel.url {
                    try? FileManager.default.removeItem(at: dest)
                    try? FileManager.default.copyItem(at: url, to: dest)
                }
            }
            #endif
        }
    }

    private func shareText(_ text: String) {
        DispatchQueue.main.async {
            #if os(iOS)
            self.presentShare([text])
            #else
            self.macShare([text])
            #endif
        }
    }

    #if os(iOS)
    private func presentShare(_ items: [Any]) {
        guard let top = topController() else { return }
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let pop = vc.popoverPresentationController, let v = webView {
            pop.sourceView = v
            pop.sourceRect = CGRect(x: v.bounds.midX, y: v.bounds.midY, width: 1, height: 1)
        }
        top.present(vc, animated: true)
    }
    #else
    private func macShare(_ items: [Any]) {
        guard let v = webView else { return }
        let picker = NSSharingServicePicker(items: items)
        picker.show(relativeTo: NSRect(x: v.bounds.midX, y: v.bounds.midY, width: 1, height: 1), of: v, preferredEdge: .minY)
    }
    #endif
}

// MARK: - WebKit delegates

extension NativeBridge: WKUIDelegate, WKNavigationDelegate {

    // Microphone for the tuner, karaoke and "Wait" mode
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.grant)
    }

    // Links that open a new window go to the browser
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { openURL(url) }
        return nil
    }

    // Keep the app on the Song Coach site; other sites open in the browser
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { return decisionHandler(.allow) }
        let scheme = url.scheme?.lowercased() ?? ""
        if ["mailto", "tel", "sms"].contains(scheme) { openURL(url); return decisionHandler(.cancel) }
        if navigationAction.targetFrame?.isMainFrame == true, ["http", "https"].contains(scheme),
           let host = url.host, host != NativeBridge.siteURL.host,
           !host.hasSuffix("google.com"), !host.hasSuffix("firebaseapp.com"), !host.hasSuffix("googleapis.com") {
            openURL(url); return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pushDeviceList()
    }

    // alert / confirm / prompt from the page
    #if os(iOS)
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        if let top = topController() { top.present(a, animated: true) } else { completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        if let top = topController() { top.present(a, animated: true) } else { completionHandler(false) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let a = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        a.addTextField { $0.text = defaultText }
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(a.textFields?.first?.text) })
        if let top = topController() { top.present(a, animated: true) } else { completionHandler(nil) }
    }
    #else
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert(); a.messageText = message; a.addButton(withTitle: "OK"); a.runModal(); completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert(); a.messageText = message; a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        completionHandler(a.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let a = NSAlert(); a.messageText = prompt; a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); field.stringValue = defaultText ?? ""
        a.accessoryView = field
        completionHandler(a.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }

    // file inputs (importing songs / sheet music)
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        completionHandler(panel.runModal() == .OK ? panel.urls : nil)
    }
    #endif
}

extension NativeBridge: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(iOS)
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
        return windows.first { $0.isKeyWindow } ?? windows.first ?? ASPresentationAnchor()
        #else
        return webView?.window ?? NSApp.keyWindow ?? ASPresentationAnchor()
        #endif
    }
}

/// Avoids a retain cycle between the web view's content controller and the bridge.
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: NativeBridge?
    init(_ target: NativeBridge) { self.target = target }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.handle(message.body)
    }
}
