import SwiftUI
import WebKit

#if os(iOS)
struct SongCoachWebView: UIViewRepresentable {
    let bridge: NativeBridge
    func makeUIView(context: Context) -> WKWebView { bridge.makeWebView() }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#else
struct SongCoachWebView: NSViewRepresentable {
    let bridge: NativeBridge
    func makeNSView(context: Context) -> WKWebView { bridge.makeWebView() }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#endif
