import SwiftUI

@main
struct RippleApp: App {
    var body: some Scene {
        WindowGroup {
            WaterView()
                .ignoresSafeArea()
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
                .preferredColorScheme(.dark)
        }
    }
}
