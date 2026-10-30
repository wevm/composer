import ComposerCore
import ComposerStyled
import ComposerSwiftUI
import SwiftUI

@main
struct PlaygroundApp: App {
  var body: some Scene {
    WindowGroup {
      #if os(macOS)
        MacPlayground()
      #else
        NavigationStack {
          ContentUnavailableView(
            "Composer Playground", systemImage: "text.cursor",
            description: Text("The iOS demo lands with the UIKit engine."))
        }
      #endif
    }
  }
}
