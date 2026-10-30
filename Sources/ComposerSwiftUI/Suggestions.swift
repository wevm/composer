#if canImport(SwiftUI)
  import SwiftUI

  extension Composer {
    /// The Suggestions slot: the open suggestion list, for mentions,
    /// hashtags, slash commands, and emoji. Empty while no list is open.
    /// Tapping a row commits it; ↑, ↓, ↩, ⇥, and Esc work from the input.
    ///
    /// It observes only the suggestion session, so typing outside a trigger
    /// doesn't invalidate it.
    public struct Suggestions<Row: View>: View {
      @Environment(ComposerController.self) private var controller
      private let row: (Suggestion, Bool) -> Row

      /// Rows rendered by `row`, given the item and whether it is
      /// highlighted.
      public init(@ViewBuilder _ row: @escaping (Suggestion, _ isHighlighted: Bool) -> Row) {
        self.row = row
      }

      public var body: some View {
        if let session = controller.suggestionSession, session.isActive,
          !session.items.isEmpty
        {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(session.items.enumerated()), id: \.element.id) { index, item in
              Button {
                controller.suggestions.commit(index)
              } label: {
                row(item, index == session.highlightedIndex)
                  .contentShape(.rect)
              }
              .buttonStyle(.plain)
              #if os(macOS)
                .onHover { inside in
                  if inside { controller.suggestions.highlight(index) }
                }
              #endif
            }
          }
          .accessibilityElement(children: .contain)
          .accessibilityLabel(Text("Suggestions"))
        }
      }
    }
  }

  extension Composer.Suggestions where Row == Composer.StyledSuggestionItem {
    /// Rows in the environment's `SuggestionItemStyle`: the label, and the
    /// subtitle if there is one.
    public init() {
      self.init { item, isHighlighted in
        Composer.StyledSuggestionItem(
          .init(
            label: HStack {
              Text(item.label)
              if let subtitle = item.subtitle {
                Text(subtitle).foregroundStyle(.secondary)
              }
            },
            isHighlighted: isHighlighted))
      }
    }
  }
#endif
