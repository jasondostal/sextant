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
        // an iPhone 15 Pro Max in landscape at half size; `-portrait YES` stands it up
        .defaultSize(width: UserDefaults.standard.bool(forKey: "portrait") ? 430 : 926,
                     height: UserDefaults.standard.bool(forKey: "portrait") ? 932 : 427)
        #endif
    }
}
