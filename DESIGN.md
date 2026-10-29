# Composer — design

A headless, plugin-based, native text composer for iOS and macOS. It handles markdown that turns into rich text as you type, slash commands, @mentions, #hashtags, configurable actions (send, attachments, …), and a selection toolbar. It also ships a read-only renderer for sent messages.

"Headless" works the way Base UI does: Composer owns the behavior, the state, and the accessibility, and the consumer owns every pixel. A reference design, `ComposerStyled`, is built entirely from the public styling surface. It is one consumer among others, not a privileged layer.

This document records the decisions made while scoping the project. Where a reason isn't obvious, it is given with the decision. It is the reference for the implementation threads and for the conformance suite. Swift snippets are sketches that show the shape of the API. They are not final signatures.

## Goals and non-goals

Goals:

- **Headless.** Every visual is replaceable. State, commands, slots, and geometry are exposed as data.
- **Plugins all the way down.** The core has no features turned on. Markdown, mentions, send, and the rest are plugins, and the defaults are a preset.
- **Native first, and fast.** Text input, list content, hit-testing, hover, and keys run on UIKit and AppKit with TextKit 2. SwiftUI handles composition and styling. Performance budgets are measured in CI (see [Performance](#performance)).
- **Markdown in, markdown out.** Existing wevm apps store messages as markdown strings, so markdown must round-trip losslessly through the structured model (see [Markdown](#markdown)).
- **Explicit platform differences.** iOS and macOS may behave differently, for example a send button on iOS and Return-to-send on macOS. Each difference is written down, configurable, and covered by tests.
- **Platform features stay on:** VoiceOver, Dynamic Type, RTL, spellcheck, autocorrect, dictation, and Writing Tools.

Non-goals (these are the app's job, or out of scope):

- Keyboard avoidance and interactive keyboard dismissal. The Playground shows how to do them.
- Draft persistence. Drafts are serializable, and the app stores them.
- Installing menu-bar items. The keymap is exported so apps can build their own menus.
- Upload logic. The app uploads, and Composer tracks the status.
- Inline attachments, headings, tables, images, and underline.
- Collaborative editing.

## Project

| Item           | Decision                                                                                                         |
| -------------- | ---------------------------------------------------------------------------------------------------------------- |
| Repository     | `wevm/composer`, public                                                                                          |
| License        | MIT                                                                                                              |
| Status         | Alpha. Releases are `0.0.x` patch bumps (see [Releases](#releases)). No API stability promise and no full docs yet |
| OS floor       | iOS 26, macOS 26, the same as zero-swift. No `#available` branches                                               |
| Toolchain      | `swift-tools-version: 6.2`, Swift 6 language mode, strict concurrency                                            |
| Linux          | `ComposerCore` and the pure part of `ComposerTesting` build and test on Linux. Everything else is Apple-only     |
| Dependencies   | No runtime dependencies. Test-only dependencies are allowed (`swift-snapshot-testing`). The markdown parser is our own |
| Tests          | Swift Testing. XCTest only for UI and performance tests                                                          |
| Formatting     | `swift-format`, 2-space indent and 100-character lines (zero-swift's `.swift-format`). No SwiftLint              |
| CI             | Linux (Core builds and tests) and `macos-26` (iOS simulator and macOS). The `macos-26` job gates merges          |
| Identifiers    | Reverse-DNS root `dev.wevm`, for example the pasteboard type `dev.wevm.composer.document`                        |
| First consumer | The Playground app in this repository. zbugs-swift (in `wevm/zero`) adopts it once the alpha is usable, replacing its comment `TextField` |

Why iOS 26 and macOS 26: they bring `Observations` and automatic observation tracking in UIKit and AppKit (`updateProperties()`). That lets one `@Observable` controller drive SwiftUI, UIKit, and AppKit, which the headless design depends on. Matching zero-swift also keeps the floors aligned for zbugs-swift.

Why no dependencies: the composer sits in the keystroke hot path and gets embedded in other SDKs' apps. A markdown parser limited to the supported subset (see [Markdown](#markdown)) is small. Owning it also lets the parser keep unsupported syntax as literal text, which a general-purpose parser would turn into nodes we would then have to drop.

### Package and products

One SwiftPM package with six library products and one internal target:

| Target            | Kind     | Contents                                                                                            | Depends on                     |
| ----------------- | -------- | --------------------------------------------------------------------------------------------------- | ------------------------------ |
| `ComposerCore`    | product  | The document model, state, schema, codecs, plugin protocols, keymap, command bus, `ComposerController`, the v1 plugins' logic, and `Document → AttributedString` | Foundation                     |
| `ComposerTextKit` | internal | TextKit 2 code shared by UIKit and AppKit: layout fragments, attribute mapping, and the changeset applier | `ComposerCore`                 |
| `ComposerUIKit`   | product  | `ComposerTextView`, `ComposerContentView`, and native anchoring, key commands, and edit menus on UIKit | `ComposerCore`, `ComposerTextKit` |
| `ComposerAppKit`  | product  | The same on AppKit                                                                                   | `ComposerCore`, `ComposerTextKit` |
| `ComposerSwiftUI` | product  | Representables and the compound primitives in the `Composer` namespace (`Composer.Root`, `Composer.Input`, …) | `ComposerCore`, the native product for the platform |
| `ComposerStyled`  | product  | The reference design, for SwiftUI and native, and the String Catalog with its labels                 | the above                      |
| `ComposerTesting` | product  | The conformance harness: the session format, builders, and assertions (pure Swift, Linux too), plus native session drivers behind `#if canImport(UIKit)` / `#if canImport(AppKit)` | `ComposerCore`, and the native products where available |

Why the core is `ComposerCore` and not `Composer`: the SwiftUI primitives are spelled `Composer.Root`, `Composer.Input`, and so on, so `Composer` is a namespace in `ComposerSwiftUI`. A module with the same name would make that namespace ambiguous to refer to.

Why one `ComposerTesting` product: the session format and assertions are plain data and code, so Core-level tests use them on Linux. Only the drivers that run a session against a real text view need UIKit or AppKit, and `#if canImport` keeps them out of the Linux build. Zero uses the same pattern.

Why an internal `ComposerTextKit` target: TextKit 2 (`NSTextLayoutManager`, `NSTextContentStorage`, layout fragments) is the same API on both platforms. Sharing the changeset applier and attribute mapping means the two engines diverge only in view and event code, which is the part the conformance suite compares.

Layout follows zero-swift: `Sources/<Target>` and `Tests/<Target>Tests`.

```
Package.swift
VERSION
DESIGN.md
Sources/
  ComposerCore/
  ComposerTextKit/
  ComposerUIKit/
  ComposerAppKit/
  ComposerSwiftUI/
  ComposerStyled/
  ComposerTesting/
Tests/
  ComposerCoreTests/        Linux and macOS
  ConformanceTests/         Apple-only
  PerformanceTests/         Apple-only
  StyledSnapshotTests/      Apple-only
Playground/
  project.yml               XcodeGen: iOS and macOS app targets, UI tests
```

```swift
// swift-tools-version: 6.2
// Sketch.
import PackageDescription

let package = Package(
  name: "Composer",
  platforms: [.iOS(.v26), .macOS(.v26)],
  products: [
    .library(name: "ComposerCore", targets: ["ComposerCore"]),
    .library(name: "ComposerUIKit", targets: ["ComposerUIKit"]),
    .library(name: "ComposerAppKit", targets: ["ComposerAppKit"]),
    .library(name: "ComposerSwiftUI", targets: ["ComposerSwiftUI"]),
    .library(name: "ComposerStyled", targets: ["ComposerStyled"]),
    .library(name: "ComposerTesting", targets: ["ComposerTesting"]),
  ],
  dependencies: [
    // Test-only: snapshot tests of ComposerStyled.
    .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.17.0")
  ],
  targets: [
    .target(name: "ComposerCore"),
    // Internal: TextKit 2 shared by the UIKit and AppKit engines.
    .target(name: "ComposerTextKit", dependencies: ["ComposerCore"]),
    .target(name: "ComposerUIKit", dependencies: ["ComposerCore", "ComposerTextKit"]),
    .target(name: "ComposerAppKit", dependencies: ["ComposerCore", "ComposerTextKit"]),
    // …
    .testTarget(name: "ComposerCoreTests", dependencies: ["ComposerCore", "ComposerTesting"]),
    // Apple-only: ConformanceTests, PerformanceTests, StyledSnapshotTests.
  ],
  swiftLanguageModes: [.v6]
)
```

The Playground (`Playground/`, an XcodeGen `project.yml`) has iOS and macOS app targets. It demos every plugin and hosts the UI tests that need a running app. It also shows the app-owned pieces: keyboard avoidance, a fullscreen editor driven by `isExpanded`, and draft persistence.

## Architecture

This follows first principles and idiomatic Swift, not literal Clean Architecture layers. Two rules apply:

1. **Dependencies point inward.** Core knows nothing about UIKit, AppKit, or SwiftUI. Native engines depend on Core. SwiftUI depends on Core and the native engines. Styled depends on all of them and adds no behavior.
2. **Functional core, imperative shell.** Documents, selections, state, transforms, codecs, and commands are pure `Sendable` values and functions in Core. The shell is the native text views, the undo manager, the pasteboard, and timers. It feeds events in and applies changesets out.

```
ComposerStyled ──► ComposerSwiftUI ──► ComposerUIKit / ComposerAppKit ──► ComposerTextKit ──► ComposerCore
      └────────────────────────────────────────►┘                                                ▲
ComposerTesting ─────────────────────────────────────────────────────────────────────────────────┘
```

Why Core owns the headless layer: `ComposerController` is an `@Observable`, `@MainActor` class in Core. It holds the state and runs the commands. It also exposes slots as data and holds the suggestion, hover, and selection state together with their geometry. Because it has no UI framework dependency, behavior is tested on Linux, and SwiftUI, UIKit, and AppKit share one implementation of every rule. The UI layers only render it and report events to it.

Why native first: SwiftUI's text editing can't provide what the composer needs, which is TextKit 2 control, marked-text hooks, key equivalents, attachment view providers, and precise hit-testing. List cells pay for every allocation. So the hot paths are native and public: input, list content, hit-testing, hover, and keys. SwiftUI is a thin binding for composition and styling. If UIKit or AppKit does something better, that layer does it, not SwiftUI.

Lexical and ProseMirror were references, not constraints. The model below borrows Lexical's node transforms and command priorities and ProseMirror's schema. It drops what only collaborative editing needs.

## Core model

### Document

The structured model is canonical. Markdown and JSON are import and export formats.

```swift
public struct Document: Sendable, Hashable, Codable {
  public var blocks: [Block]
}

public enum Block: Sendable, Hashable {
  case paragraph([Inline])
  case codeBlock(language: String?, text: String)  // the fence language is kept
  case quote([Block])
  case list(ListKind, items: [ListItem])           // nested up to 3 levels; deeper imports are clamped
}

public enum ListKind: Sendable, Hashable { case bullet, ordered(start: Int) }

public struct ListItem: Sendable, Hashable {
  public var checked: Bool?                        // nil: plain item; true/false: GFM task item
  public var blocks: [Block]
}

public enum Inline: Sendable, Hashable {
  case text(String, marks: Marks)           // bold, italic, strikethrough, code, link
  case node(AtomicNode)                     // mentions, hashtags, slash tokens, custom tokens
  case unknown(UnknownNode)                 // a JSON node type with no registered plugin
}

public struct AtomicNode: Sendable, Hashable {
  public var type: NodeType                 // e.g. "mention"
  public var label: String                  // e.g. "tom"
  public var attributes: [String: String]   // e.g. ["id": "user_123"]
}
```

- Inline content is a list of runs. Atomic nodes are typed and indivisible: delete and select treat them as one unit.
- Node types are open. Plugins register them, together with their codecs, in the schema. The core schema registers nothing.
- Marks nest freely, except that nothing nests inside inline code.
- An `UnknownNode` keeps a JSON node verbatim when its type has no registered plugin (see [JSON](#json)).

### Selection and state

```swift
public struct Selection: Sendable, Hashable {
  public var anchor: Position
  public var head: Position
}

public struct EditorState: Sendable {   // copy-on-write storage
  public var document: Document
  public var selection: Selection
  public var markedText: MarkedText?    // IME composition in progress
  public var attachments: [Attachment]
  public var context: (any ComposerContext)?   // reply or edit (see Reply and edit)
  public subscript<State>(key: PluginKey<State>) -> State { get set }   // typed plugin state
}
```

`EditorState` is a copy-on-write struct. Snapshots are cheap, so undo, tests, and conformance comparisons get them for free. Equality is meaningful, so two engines can be compared value for value.

### Updates

Every change goes through one entry point:

```swift
controller.update { state in
  state.insert("hello", at: state.selection)
}
```

An update runs in this order:

1. The closure mutates the state `inout`.
2. **Node transforms** run on the dirty ranges until nothing changes (a fixed point). Input rules and token recognition are transforms. Running them only on dirty ranges keeps the cost per keystroke proportional to the edit, not to the document.
3. The update emits a **changeset**: the dirty ranges plus the selection delta. It is deliberately lightweight.
4. Engines apply the changeset to their `NSTextStorage` by diffing only the dirty ranges, never by replacing the whole storage. This is what keeps a keystroke under the 4 ms budget. The applier is shared in `ComposerTextKit`.
5. Observation fires. Fine-grained `@Observable` properties make sure a keystroke only invalidates views that depend on the text or the selection, not the actions, slots, or attachments.

### Commands

Commands go through a **priority bus**. Handlers are called from highest priority to lowest. The first one that returns `.handled` stops propagation. That is how the suggestion plugin claims ↑ and ↩ while a menu is open and lets them through otherwise.

```swift
public struct Command<Payload: Sendable>: Sendable, Hashable { public let name: String }

extension Command where Payload == Void {
  public static let send = Command(name: "send")
  public static let toggleBold = Command(name: "toggleBold")
  public static let toggleTask = Command(name: "toggleTask")
}

controller.register(.send, priority: .high) { payload, controller in
  guard controller.suggestions.isActive else { return .unhandled }
  controller.suggestions.commit()
  return .handled
}

controller.run(.toggleBold)
```

### Undo

Undo uses the native `UndoManager`, so ⌘Z, the Edit menu, and shake-to-undo work as users expect. Changesets are coalesced into undo groups (consecutive typing becomes one group). Composer does not keep its own undo stack.

### IME and marked text

Transforms and input rules are paused while marked text exists, and they run when the composition is committed. Rewriting text under an active composition breaks Japanese, Chinese, and Korean input as well as dictation.

### Single user

There is no collaborative editing, so there are no ProseMirror-style steps and no position mapping. One thing needs a stable range across edits: a suggestion query that is waiting on an async source. The trigger plugin tracks that range itself.

## Serialization

### Markdown

Markdown is the interchange format, because apps store markdown strings. The dialect is GFM.

**Lossless means semantic, not byte for byte:**

- `parse(serialize(doc)) == doc` for every document.
- Export uses one canonical form: `**bold**`, `_italic_`, `~~strike~~`, and `-` bullets. So `*a*` imports as italic and re-exports as `_a_`.
- Re-export is idempotent after the first pass: `serialize(parse(serialize(parse(md)))) == serialize(parse(md))`.
- Content is never dropped. Syntax the dialect doesn't support stays as literal text.

Why semantic: byte-exact round-tripping would force the model to record every spelling choice (`*` or `_`, `-` or `*`, escapes, whitespace) that the user can neither see nor edit. Messages that are already stored keep their meaning. They change bytes at most once, on the first edit.

The supported dialect:

| Syntax                                    | Support                                                                 |
| ----------------------------------------- | ----------------------------------------------------------------------- |
| `**bold**`, `_italic_`, `~~strike~~`      | yes; marks nest freely                                                  |
| `` `code` ``                              | yes; nothing nests inside it                                            |
| `[text](url)`, autolinks                  | yes                                                                     |
| Fenced code blocks                        | yes; the fence language is kept                                         |
| `> quote`                                 | yes                                                                     |
| `-` and `1.` lists                        | yes; ordered and unordered, nested up to 3 levels (deeper nesting on import is clamped) |
| `- [ ]` / `- [x]` task lists              | yes; toggleable                                                         |
| Headings, tables, images, raw HTML        | no; kept as literal text                                                |

- Export escapes only characters that would otherwise parse as syntax. A `*` between spaces stays as it is.
- Lists nested deeper than 3 levels, in imported markdown or pasted HTML, are clamped to level 3: the deeper items become level-3 items, in their original order, and no text is lost.

### Directives and node codecs

Codecs are configured per node type, and each has a default:

- Atomic nodes (mentions, custom tokens, slash tokens) default to generic directives, for example `:mention[tom]{#user_123}`. Directives are a CommonMark *proposal* implemented by `remark-directive`. They are not part of the CommonMark spec or GFM. They are the default because they are generic: they carry a type, a label, and attributes without app-specific syntax, and JS clients can parse them with an existing library. Because they are not standard, the codec can be replaced.
- Hashtags default to plain `#tag`, which every markdown renderer already shows sensibly.

```swift
MentionsPlugin(source: users)
  .codec(.directive(name: "mention"))   // default
  .codec(.custom(encode: { "<@\($0.attributes["id"]!)>" }, decode: slackMention))
```

### JSON

JSON is the `Codable` form of `Document`, used for drafts, the private pasteboard type, and wherever markdown would lose information.

```json
{
  "version": 1,
  "blocks": [
    {
      "type": "paragraph",
      "children": [
        { "type": "text", "text": "hi ", "marks": ["bold"] },
        { "type": "mention", "text": "@tom", "attrs": { "id": "user_123", "label": "tom" } }
      ]
    }
  ]
}
```

- Field names other than `version`, `type`, `text`, and `attrs` in the example are illustrative.
- The document has a top-level `version` integer.
- Nodes are objects of the form `{ "type", "attrs", … }`.
- Every atomic node has a required top-level `"text"` field holding its fallback text, for example `"@tom"` for a mention. Each node type's encoder always writes it.
- A node whose type has no registered plugin decodes to an opaque `UnknownNode`. It keeps its JSON verbatim, renders and exports to markdown as its `text`, and encodes back to the same JSON. If `text` is missing, as in hand-written JSON, the node renders as `[type]`, for example `[poll]`, and its JSON is still kept verbatim. A composer configured with fewer plugins than the one that wrote a draft therefore never destroys content.

## Plugins

Everything is a plugin, and the core turns no features on. A plugin contributes to one or more extension points:

| Extension point          | Used for                                                       |
| ------------------------ | -------------------------------------------------------------- |
| Input rules              | `**bold**` → bold, `> ` → quote, `- ` → list, `- [ ] ` → task  |
| Triggers                 | `@`, `#`, `/`, `:`: open a suggestion session                  |
| Node types (+ codecs)    | mention, hashtag, emoji, slash token, custom tokens            |
| Decorations and styling  | `TokenStyle` providers, code block monospace, highlighting     |
| Commands                 | `toggleBold`, `toggleTask`, `send`, `editLink`, …              |
| Keymap bindings          | ⌘B, ↩, ↑, …                                                    |
| Paste and drop handlers  | autolink on paste, URL over selection, rich paste, attachment sources |
| Actions and slot content | the send button, the attachment picker, footer counters        |
| Lifecycle hooks          | `willSend`, `didChange`                                        |

```swift
public protocol ComposerPlugin: Sendable {
  func register(in registry: inout PluginRegistry)
}

public struct PluginKey<State: Sendable>: Sendable, Hashable {
  public init(_ name: String, default: State)
}
```

- Registration uses a result builder that produces `[any ComposerPlugin]`. A plain array is also accepted.
- Plugin state is typed and lives in `EditorState` under a `PluginKey<State>`, so it is copied, compared, and undone along with the document.

### `.chatDefaults`

`.chatDefaults` is the preset for features that need no app input:

- all the markdown rules, including task lists;
- autolink, paste-link-over-selection, and ⌘K link editing;
- the platform keymap;
- both selection-toolbar plugins, with the platform defaults;
- clipboard handling (rich paste, markdown paste, copy).

Everything that needs app data or a decision is added explicitly with its own parameters: send, mentions, hashtags, slash commands, attachments, reply and edit contexts, max length, emoji shortcodes, and type-to-focus.

```swift
let controller = ComposerController {
  .chatDefaults
  SendAction { message in try await api.post(message.markdown) }
  MentionsPlugin(source: UserSearch(api))
  HashtagsPlugin()
  EmojiShortcodesPlugin(emoji: myEmoji)
}
// An array works too: ComposerController(plugins: [MarkdownBold(), SendAction(onSend: post)])
```

### v1 plugins

#### Markdown

- Converts as you type: typing `**bold**` produces bold text, and backspace right after a conversion reverts it to the literal characters.
- Supported: bold, italic, strikethrough, inline code, links, code blocks, quotes, ordered and unordered lists, and task lists (see [Markdown](#markdown) for the dialect). Headings, tables, and images are not supported.
- **Each rule is its own plugin**, so apps can, for example, take bold without lists.
- Task list items can be toggled by clicking or tapping the checkbox, and with the `toggleTask` command.
- Code blocks are monospace. The fence language is kept in the document. There is a `CodeHighlighter` protocol hook, and v1 does no highlighting.
- The markdown plugins contribute the slash commands `/quote`, `/code`, and `/list`.

```swift
public protocol CodeHighlighter: Sendable {
  func highlight(_ code: String, language: String?) -> [HighlightRun]
}
```

#### Suggestions: mentions, hashtags, slash commands

The suggestion machinery is shared and headless. The controller exposes the active trigger, the query, the anchor rect, the highlighted index, and the loading and empty states. Composer handles ↑, ↓, ⇥, ↩, and Esc. The consumer renders the list.

```swift
public protocol SuggestionSource<Item>: Sendable {
  associatedtype Item: Sendable & Identifiable
  func results(for query: String) async throws -> [Item]
}

MentionsPlugin(source: .static(users))              // debounce 0 ms
MentionsPlugin(source: UserSearch(api))             // debounce 120 ms
MentionsPlugin(source: UserSearch(api), debounce: .milliseconds(200))

// Headless state that the consumer reads:
controller.suggestions.trigger          // "@"
controller.suggestions.query            // "to"
controller.suggestions.anchorRect       // in the input's coordinate space
controller.suggestions.items            // [AnySuggestion]
controller.suggestions.highlightedIndex
controller.suggestions.phase            // .loading / .results / .empty
```

- A stale query is cancelled automatically when the query changes.
- The debounce defaults to 0 ms for static sources, which answer instantly, and 120 ms for async sources, so a fast typist doesn't send a request per keystroke. It is configurable.
- **Hashtags** use the same machinery. Their source is optional. A freeform `#tag` turns into a token on space or punctuation.
- **Slash commands** return one of three results and may take arguments:

```swift
public enum SlashResult: Sendable {
  case perform              // run a side effect; the `/cmd` text is removed
  case insert(AtomicNode)   // replace `/cmd` with a token
  case replace(String)      // replace `/cmd` with text
}
```

#### Emoji shortcodes

`:smile:` support is opt-in and not part of `.chatDefaults`. The consumer supplies the emoji data. No dataset ships with Composer.

#### Links

These are separate plugins, all in `.chatDefaults`:

- **Autolink**, both while typing and on paste.
- **Paste a URL over a selection** to make the selection a link.
- **⌘K link editing**, a headless state with the range, the URL, and `apply` and `remove`. The consumer renders the editor.

#### Send

`SendAction` sends a `ComposerMessage`:

```swift
public struct ComposerMessage: Sendable {
  public var document: Document
  public var markdown: String
  public var attachments: [Attachment]
  public var context: (any ComposerContext)?
}

SendAction { message in try await api.post(message.markdown) }
  .clearing(.immediately)   // default; .afterSuccess waits
```

- Sending is `async throws`.
- By default the composer clears immediately and restores the draft if the send throws. Chat feels instant, and nothing is lost on failure. Waiting for success before clearing is configurable.

`willSend` hooks run before the send:

```swift
public enum SendDecision: Sendable { case proceed, cancel }

// A lifecycle hook contributed by a plugin, with a priority.
func willSend(_ message: inout ComposerMessage) async throws -> SendDecision
```

- Hooks run in priority order, each seeing the message as the previous hook left it.
- A hook can modify the message, return `.cancel` to veto the send (the draft stays), or throw (the draft is restored, as when the send itself throws).
- Hooks that only observe return `.proceed`.

#### Attachments

v1 has an attachments tray only, no inline attachments.

```swift
public struct Attachment: Sendable, Identifiable {
  public var id: ID
  public var payload: any Sendable          // generic, owned by the app
  public var status: Status
  public enum Status: Sendable { case pending, uploading(progress: Double), failed(any Error), ready }
}
```

- `[Attachment]` lives in the state. The consumer does the upload and updates the status.
- Paste, drop, and the picker are each a source plugin. Images in a rich paste go to the Attachments plugin when it is enabled (see [Clipboard](#clipboard)).
- Send is blocked while an attachment is uploading. This is the default `isEnabled` of the send action, so it can be overridden.

#### Reply and edit

- A typed `context` in the state, rendered in the Header slot. Esc clears it.
- While editing, the send label becomes "Save".
- ↑ in an empty composer edits the last message. This is a hook, because only the app knows what the last message is.
- The context is included in the `ComposerMessage`.

#### Max length

- There is no limit by default. The plugin is added explicitly with a limit.
- The limit is hard or soft, configurable. A **soft** limit lets the user keep typing: the Footer shows the overflow and send is disabled. A **hard** limit stops input at the limit. A paste that would exceed it is truncated to fit, and the plugin emits a `didTruncate` event so the app can tell the user.
- The counting function is configurable. By default it is the length of the serialized markdown, because that is what the server stores and limits.

```swift
MaxLength(5_000, mode: .soft)
MaxLength(5_000, mode: .hard, count: { $0.plainText.count })
  .onDidTruncate { removed in toast("Pasted text was shortened") }
```

#### Type-to-focus

An opt-in macOS plugin: typing while the window has no focused text input focuses the composer and delivers the keystroke.

#### Selection toolbar

There are two plugins, both in `.chatDefaults`:

- **Floating toolbar (headless):** the selection rect, the active marks, and the formatting commands. The consumer renders it.
- **Edit-menu items (native):** formatting items added to the system edit menu.

The platform defaults are a floating toolbar on macOS, and on iOS the edit-menu items plus an optional format row in the keyboard accessory.

### Token rendering

By default, tokens render as styled text runs that are atomic for deletion and selection. `TokenStyle` providers style them. This is cheap and keeps text behaviors (selection, VoiceOver, Writing Tools) intact.

As an opt-in for each node type, a token can render as a view through TextKit 2's `NSTextAttachmentViewProvider`, for example an avatar chip.

```swift
MentionsPlugin(source: users)
  .tokenStyle { node in TokenStyle(foreground: .accent, background: .accent.opacity(0.12)) }
  .attachmentView { node in AvatarChipProvider(node) }   // opt-in
```

## Headless UI

### Slots

| Slot              | Contents                                         |
| ----------------- | ------------------------------------------------ |
| Header            | reply and edit banners                           |
| Attachments       | the tray, above the input                        |
| LeadingActions    | e.g. the attachment picker                       |
| Input             | the text view                                    |
| TrailingActions   | e.g. send                                        |
| Suggestions       | the mention, hashtag, slash, and emoji list      |
| SelectionToolbar  | the floating formatting toolbar                  |
| Footer            | the character count, hints, typing indicators    |
| Placeholder       | shown while the document is empty                |
| KeyboardAccessory | iOS only: `inputAccessoryView`                   |

Slots are data on the controller. Plugins contribute to them, and any UI layer renders them.

### Actions

Actions are values. Plugins and consumers both provide them.

```swift
public struct ComposerAction: Sendable, Identifiable {
  public var id: ID
  public var label: LocalizedStringResource
  public var systemImage: String?
  public var placement: Placement.PerPlatform      // e.g. .trailing on iOS, .none on macOS
  public var isEnabled: @Sendable (EditorState) -> Bool
  public var isVisible: @Sendable (EditorState) -> Bool
  public var perform: @MainActor (ComposerController) async throws -> Void
}

ForEach(composer.actions(.trailing)) { action in
  Button(action.label, systemImage: action.systemImage ?? "", action: { … })
}
```

Consumers either loop over a placement, as above, or place individual actions by id.

### Hover

Hover is headless in both the input and the read-only content. The controller exposes the hovered node and its anchor rect, and the consumer renders the tooltip or hover card.

- Hover intent opens after **500 ms** and has a **150 ms grace period**: the card stays open while the pointer travels from the text to the card, so cards don't flicker as the pointer crosses text.
- It works with macOS and iPad pointers. iPhone uses long-press and context menus instead.
- `ComposerStyled` ships a link-URL tooltip and an example user card.

## Native layers: `ComposerUIKit` and `ComposerAppKit`

These are complete public APIs, not internals of the SwiftUI layer. The TextKit 2 code they share lives in the internal `ComposerTextKit` target.

- **`ComposerTextView`** is TextKit 2, based on `UITextView` or `NSTextView`. It implements the `TextEngine` protocol, which is the boundary between Core and a platform text system: it reports events in and applies changesets out.
- **`ComposerContentView`** is the read-only view for `UICollectionView` and `NSTableView` cells. It draws attributed text directly for plain content and uses TextKit only when the content is interactive, so scrolling lists stay cheap.
- **Native anchoring** for popovers and hover cards: `NSTrackingArea` with `NSPopover` or a child window on macOS, and `UIPointerInteraction` and `UIEditMenuInteraction` on iOS.
- **Keys** go through `performKeyEquivalent` on macOS and `UIKeyCommand` on iOS, with discoverability titles so they show in the iPad shortcut overlay.
- **Styling** uses closures and configuration on the views:

```swift
let textView = ComposerTextView(controller: controller)
textView.textStyles = .init(base: .preferredFont(forTextStyle: .body), bold: …, code: …)
textView.actionViewProvider = { action in MyActionButton(action) }
textView.suggestionCellProvider = { collectionView, indexPath, item in … }
```

```swift
public protocol TextEngine: AnyObject {
  @MainActor func apply(_ changeset: Changeset, from state: EditorState)
  @MainActor var selectionRects: [CGRect] { get }
  @MainActor func rect(for range: DocumentRange) -> CGRect
}
```

## SwiftUI: `ComposerSwiftUI`

A thin binding: representables around the native views, plus compound primitives in the `Composer` namespace that share context through the environment.

```swift
import ComposerSwiftUI

Composer.Root(controller) {
  Composer.Header { context in ReplyBanner(context) }
  Composer.Attachments { attachment in Thumbnail(attachment) }
  HStack {
    Composer.Actions(.leading)
    Composer.Input(isExpanded: $expanded)      // 1–8 lines on iOS, 1–12 on macOS
      .focused($focused)
    Composer.Actions(.trailing)
  }
  Composer.Suggestions { item, isHighlighted in Row(item, isHighlighted) }
  Composer.SelectionToolbar { toolbar in MyToolbar(toolbar) }
  Composer.Footer { state in Counter(state) }
}
.font(.body)
.foregroundStyle(.primary)
.tint(.blue)
.composerTextStyle(for: .mention) { $0.foregroundStyle(.blue).bold() }
```

Styling follows the `ButtonStyle` pattern. There are style protocols (`ComposerActionStyle`, `SuggestionItemStyle`, `AttachmentStyle`, …), each with a `Configuration` that carries state such as highlighted, enabled, or progress. Render closures cover one-off cases. Inside the text, the base font and color come from `.font`, `.foregroundStyle`, and `.tint`. Individual marks and tokens are styled with `.composerTextStyle(for:)`.

```swift
public protocol SuggestionItemStyle {
  associatedtype Body: View
  @ViewBuilder func makeBody(configuration: Configuration) -> Body
  typealias Configuration = SuggestionItemStyleConfiguration   // item, isHighlighted, label
}
```

## Styled: `ComposerStyled`

The reference design covers both SwiftUI and native (UIKit and AppKit) in v1. It is built only from the public styles, which proves that surface is enough. It owns the String Catalog for the labels its design shows (Send, Save, Attach, …). Accessibility labels for nodes are not in it; each plugin's module localizes those (see [Accessibility](#accessibility-and-platform-features)).

## Platform behavior

Defaults are expressed as per-platform configuration in Core, and all of them can be overridden. These are the intended differences, and they are listed in the conformance allowlist.

### Return

| Where                  | macOS                                                                        | iOS                                       |
| ---------------------- | ---------------------------------------------------------------------------- | ----------------------------------------- |
| Outside blocks (plain text, quotes) | ↩ sends; ⇧↩ inserts a newline                                   | ↩ inserts a newline; the send button sends; ⌘↩ sends (hardware keyboard) |
| Code block             | ↩ inserts a newline; ↩ on an empty last line exits the block; ⌘↩ sends       | the same; ⌘↩ sends (hardware keyboard)    |
| List or task item      | ↩ creates a new item; ↩ on an empty item exits the list; ⌘↩ sends            | the same; ⌘↩ sends (hardware keyboard)    |
| Suggestions open       | ↩ commits the highlighted item                                               | the same                                  |

The block rules are the same on both platforms. The only difference is that on macOS, ↩ outside a block sends. Inside code blocks and lists, a newline or a new item is what the user means almost every time, so ↩ does that there, and ⌘↩ sends from anywhere.

### Other differences

| Behavior                   | macOS                        | iOS                                                          |
| -------------------------- | ---------------------------- | ------------------------------------------------------------ |
| Send button                | optional                     | visible (keyboard accessory or trailing)                     |
| Input lines (min–max)      | 1–12                         | 1–8                                                          |
| Selection toolbar          | floating toolbar             | edit-menu items, optional format row in the keyboard accessory |
| Hover                      | pointer                      | iPad pointer; iPhone uses long-press and context menu        |
| Type-to-focus              | opt-in plugin                | —                                                            |
| Keyboard accessory slot    | —                            | `inputAccessoryView`                                         |

## Keymap

Plugins contribute bindings, each with a priority and a `when` predicate. Consumers can override or remove any binding.

```swift
public struct KeyBinding: Sendable {
  public var key: KeyEquivalent
  public var modifiers: EventModifiers
  public var command: AnyCommand
  public var priority: Priority
  public var when: @Sendable (EditorState) -> Bool
  public var discoverabilityTitle: LocalizedStringResource?
}

controller.keymap.remove(.toggleStrikethrough)
controller.keymap.bindings   // exported, so apps can build their own menus
```

Default bindings:

| Keys          | Command                                                  |
| ------------- | -------------------------------------------------------- |
| ⌘B            | bold                                                     |
| ⌘I            | italic                                                   |
| ⌘⇧X           | strikethrough                                            |
| ⌘E            | inline code                                              |
| ⌘K            | edit link                                                |
| ↩ / ⇧↩ / ⌘↩   | send, newline, and block rules, per [Return](#return)    |
| ↑ ↓ ⇥ ↩ Esc   | suggestion navigation and commit, while suggestions are open |
| ⇥ / ⇧⇥        | indent and outdent in lists (up to 3 levels)             |
| ↑             | edit the last message, in an empty composer (hook)       |
| Esc           | clear the reply or edit context                          |

There is no ⌘U: the schema has no underline mark, because markdown has no underline syntax. Composer does not install menus.

## Input

- The input grows from `minLines` to `maxLines`, then scrolls. The defaults are 1–8 lines on iOS and 1–12 on macOS. It reports its intrinsic height without layout loops.
- An `isExpanded` binding lets the consumer build a fullscreen editor.
- It supports `.focused`.
- Controller API:

```swift
controller.focus()
controller.blur()
controller.insert(.text("hi"))
controller.insert(.node(mention))
controller.setDocument(doc)
controller.clear()
controller.run(.toggleBold)
controller.selection = Selection(…)
```

## Clipboard

### Paste

- Plain text that looks like markdown is parsed. ⌘⇧V (Paste and Match Style) pastes it literally.
- RTF and HTML are mapped to the schema, and anything the schema doesn't support is dropped. The mapping:

| Source                                      | Maps to                                                      |
| ------------------------------------------- | ------------------------------------------------------------ |
| bold trait, `<b>`, `<strong>`               | bold                                                         |
| italic trait, `<i>`, `<em>`                 | italic                                                       |
| strikethrough attribute, `<s>`, `<del>`     | strikethrough                                                |
| monospace font, `<code>`                    | inline code                                                  |
| `<pre>`                                     | code block                                                   |
| link attribute, `<a>`                       | link                                                         |
| `<blockquote>`                              | quote                                                        |
| `<ul>`, `<ol>`, `<li>`                      | lists                                                        |
| checkbox list items                         | task list items                                              |
| headings                                    | a bold paragraph                                             |
| underline, colors, fonts, sizes             | dropped                                                      |
| images                                      | handed to the Attachments plugin if it is enabled, otherwise dropped |

Headings become bold paragraphs rather than being dropped, because the words carry the meaning and the emphasis is the closest supported equivalent. A `PasteMapper` hook overrides the mapping:

```swift
public protocol PasteMapper: Sendable {
  func map(_ source: PasteSource) -> PasteResult   // .document(Document), .attachments([…]), .unhandled
}
```

### Copy

Copy writes three representations:

- markdown as plain text, for text fields and terminals;
- RTF, for rich-text apps;
- the private type `dev.wevm.composer.document`, whose payload is the JSON form, for composer to composer, so tokens and their attributes survive.

## Read-only content

`Composer.Content` (SwiftUI) and `ComposerContentView` (native) render sent messages. Both use the same text styles as the input.

- Rendering is a pure Core function, `Document → AttributedString`, so it is testable on Linux and identical everywhere.
- SwiftUI uses `Text(AttributedString)` by default, the cheapest option in long lists. It switches to the TextKit renderer automatically when the document has view-attachment tokens or when hover or context-menu handlers are attached. `.contentRenderer(.textKit)` forces TextKit.
- `.onTapNode`: tokens and links carry internal URLs that an `OpenURLAction` intercepts. Plain links open with `openURL` unless overridden.
- `.contextMenuNode` and `.onHoverNode { node, anchor in … }` work only on the TextKit path.

```swift
Composer.Content(message.document)
  .composerTextStyle(for: .mention) { $0.foregroundStyle(.blue) }
  .onTapNode { node in router.open(node) }
  .onHoverNode { node, anchor in hovered = (node, anchor) }   // switches to TextKit
```

## Accessibility and platform features

- Each node plugin supplies `accessibilityLabel(for:)`, which VoiceOver reads, for example "mention, Tom".
- Default strings, such as `"mention, %@"`, are localized in the module that defines the plugin, not in `ComposerStyled`, so a headless consumer gets correct VoiceOver output without the reference design. Consumers can override the labels.
- Dynamic Type, RTL, spellcheck, autocorrect, dictation, and Writing Tools all stay on. Nothing in the design may require turning them off. This is one reason tokens default to text runs rather than views.

```swift
MentionsPlugin(source: users)
  .accessibilityLabel { node in "\(node.label), teammate" }   // override
```

## Quality

### Tests

| Target                | Runs on        | Covers                                                        |
| --------------------- | -------------- | ------------------------------------------------------------- |
| `ComposerCoreTests`   | Linux, macOS   | Core unit tests, markdown and JSON round trips, `UnknownNode` |
| `ConformanceTests`    | macOS, iOS sim | scripted sessions against real `NSTextView` and `UITextView`  |
| `PerformanceTests`    | macOS, iOS sim | the [budgets](#performance), XCTest                           |
| `StyledSnapshotTests` | macOS, iOS sim | `ComposerStyled` only, with `swift-snapshot-testing`          |

The Playground hosts the XCTest UI tests that need a running app.

- **Round trips** check the three properties in [Markdown](#markdown): `parse(serialize(doc)) == doc`, idempotent re-export, and unsupported syntax kept as literal text. They also check that lists nested deeper than 3 levels are clamped without losing text, and that an `UnknownNode` survives JSON round trips unchanged, with or without `text`.
- **Conformance suite (`ComposerTesting`).** Scripted sessions (keys, IME marked text, paste, selection changes) run against a real `UITextView` in the iOS simulator and a real `NSTextView`, and assert that both produce identical `EditorState`s. Intended platform differences are listed in an explicit allowlist (see [Platform behavior](#platform-behavior)), so any other divergence fails. The two text systems differ in key handling, marked text, and selection affinity, and this suite is what catches those differences. The session format and assertions build on Linux, so Core tests can run the same sessions against the controller without a text view.

```swift
let session = Session {
  Type("hello **wor")
  Marked("ld", committing: "ld")
  Type("**")
  Key(.return, modifiers: .shift)
  Paste(.plainText("https://wevm.dev"))
}
// Runs on UITextView and NSTextView; expects equal EditorState except allowlisted differences.
```

- **Snapshot tests** cover `ComposerStyled` only. Headless layers are tested on state, not pixels.

### Performance

Budgets are measured in CI against the native views:

| Scenario            | Budget                              |
| ------------------- | ----------------------------------- |
| Keystroke           | < 4 ms of main-thread work          |
| 20k-character paste | no visible hitch                    |
| Mount               | < 5 ms                              |

The workload is chat-sized: usually under 2k characters, with pastes of up to about 20k. The design does not optimize for book-length documents.

### CI

- **Linux, every PR:** builds `ComposerCore` and `ComposerTesting`, runs `ComposerCoreTests`, and checks `swift-format`.
- **`macos-26`, gates merges:** all products, the iOS simulator and macOS tests, `ConformanceTests`, `PerformanceTests`, `StyledSnapshotTests`, and the Playground built for iOS and macOS.

### Releases

The same scheme as zero-swift: a `VERSION` file at the root, and a CI workflow that tags `0.0.x` when a merge to `main` changes `VERSION`.

## Milestones

| #   | Milestone                                                                                         |
| --- | ------------------------------------------------------------------------------------------------- |
| 1   | This design doc                                                                                   |
| 2   | Scaffolding: the package, CI, and the Playground                                                  |
| 3   | Core: the document model, updates and transforms, the command bus, and the markdown and JSON codecs |
| 4   | The AppKit engine and the conformance harness                                                     |
| 5   | The UIKit engine                                                                                  |
| 6   | The SwiftUI binding                                                                               |
| 7   | Triggers: mentions, hashtags, slash commands, emoji                                               |
| 8   | Actions, attachments, reply and edit contexts, max length                                         |
| 9   | Read-only content, hover, and context menus                                                       |
| 10  | The styled package and Playground polish                                                          |

AppKit comes before UIKit because the conformance harness needs one real engine to start from, and `NSTextView` runs without a simulator.

Execution policy:

- Work happens in Linux orbs by default. Apple code is written behind `#if canImport(UIKit)` / `#if canImport(AppKit)`, so it stays out of the Linux build.
- The user's Mac runner (`tmm`) is used only when Xcode or a simulator is required, as a verification pass at the end of each Apple milestone.
- The `macos-26` GitHub Actions job gates merges.

## Later

Explicitly deferred work:

- Syntax highlighting inside code blocks (the `CodeHighlighter` hook exists in v1).
- Inline attachments.
- Headings, tables, and images.
- Swapping `Text` for TextKit only while the content is hovered, if profiling shows the automatic switch costs too much.
- Full docs and a stable API (after the alpha).
- zbugs-swift adoption (in `wevm/zero`), once the alpha is usable.

## Open questions

None. Questions found during implementation go here until they are decided. The decision then moves into the relevant section.
