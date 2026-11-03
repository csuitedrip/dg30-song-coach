// Song Coach for iPhone, iPad and Mac (C-Suite Drip)
// A native shell around the Song Coach web app. It loads the live site and adds
// window.SCNative, the same bridge the Android app provides, so pianos connect
// through Apple's own MIDI system (USB and Bluetooth MIDI).

import SwiftUI

@main
struct SongCoachApp: App {
    @Environment(\.scenePhase) private var phase
    @StateObject private var bridge = NativeBridge()

    var body: some Scene {
        WindowGroup {
            SongCoachWebView(bridge: bridge)
                .ignoresSafeArea(.container, edges: .bottom)
                .onChange(of: phase) { _, newPhase in
                    bridge.setHidden(newPhase != .active)
                }
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 800)
        #endif
    }
}
