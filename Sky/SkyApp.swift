import SwiftUI

@main
struct SkyApp: App {
    var body: some Scene {
        WindowGroup {
            SkyView()
                #if os(iOS)
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
                #endif
        }
        #if os(macOS)
        // an iPhone 15 Pro in landscape, at half size
        .defaultSize(width: 926, height: 427)
        #endif
    }
}
