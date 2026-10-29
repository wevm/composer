import ComposerCore
import ComposerStyled
import ComposerSwiftUI
import SwiftUI

@main
struct PlaygroundApp: App {
  var body: some Scene {
    WindowGroup {
      NavigationStack {
        ContentUnavailableView(
          "Composer Playground", systemImage: "text.cursor",
          description: Text("The plugin demos land with the engines."))
      }
    }
  }
}
