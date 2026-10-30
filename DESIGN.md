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
  ComposerSwiftUITests/     Apple-only
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
- An `UnknownNode` keeps a JSON node verbatim when its type has no registered plugin (see [JSON](#json)). Unknown JSON *blocks* are kept the same way, as `Block.unknown`.
- Inline code never spans a line break, and a link is a mark that carries its destination, so links don't nest.

**Positions.** A `Position` is an offset into the document's linear form: its paragraphs and code blocks in order, one unit apart. Text counts in UTF-16 code units, the unit of `NSString` and TextKit, and each atomic or unknown inline node counts as one unit, so no position falls inside a token. Quotes, lists, items, and unknown blocks add no units. Editing rounds a position inside a surrogate pair down to the start of the pair. Why linear offsets: they map directly onto `NSTextStorage` ranges, so the changeset applier translates nothing.

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
  public var storedMarks: Marks?        // marks for the next typed text
  public var attachments: [Attachment]
  public var context: (any ComposerContext)?   // reply or edit (see Reply and edit)
  public subscript<State>(key: PluginKey<State>) -> State { get set }   // typed plugin state
}
```

`EditorState` is a copy-on-write struct. Snapshots are cheap, so undo, tests, and conformance comparisons get them for free. Equality is meaningful, so two engines can be compared value for value.

- Plugin state must be `Equatable` (`PluginKey<State: Sendable & Equatable>`), because it takes part in equality. Keys are identified by name. Setting a key to its default is the same as never setting it.
- `attachments` and `context` arrive with their types in milestone 8.
- **Stored marks** (decided after milestone 5). Typed text takes the stored marks if there are any, and otherwise the marks of the text before the caret. Toggling a mark with no selection (⌘B and the rest) sets stored marks at the caret, which apply to the characters typed next, until the caret moves or the mark is toggled off again. Typing uses them up, so the characters after keep the mark by following the text before them. An update that moves the selection clears them, unless it set them itself; an IME composition keeps them while its caret moves, and its committed text takes them. When a markdown closing delimiter converts a mark (`**bold**`), the conversion ends the mark there by storing the caret's marks without it, so the next characters are not bold. The markdown plugins do this when they land; the Playground's stand-in already does.

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

Details decided in milestone 3:

- A changeset's edits are sequential replacements in the linear form, each in the coordinates the previous ones left. Touching edits coalesce, so typing a word is one edit. An edit whose replacement has the same length may change attributes only. Assigning or mutating `state.document` directly is reported as the smallest replacement that turns the old linear form into the new one (text blocks compare with their containers, so a block that only moved into a list is reported too); the editing methods (`replace`, `insert`, `delete`, `splitBlock`, `setMark`, `setLink`) report exactly what they touch.
- A transform is called with the content range of each text block edited since its previous pass, and edits through the same methods, so its own edits are dirty for the next pass. Passes stop at a fixed point or at `maxTransformPasses` (32). Hitting the limit means a transform never converges; the update keeps the state it reached and sets `reachedTransformLimit` on the changeset rather than trapping, so a bad plugin can't crash the app.
- While marked text exists, edited ranges are carried over to the update that ends the composition, and transforms run on them then.
- `ComposerController.state` is one observable property for now. Splitting it so a keystroke invalidates only text and selection readers belongs to the SwiftUI binding (milestone 6).

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

- Among handlers of equal priority, the most recently registered runs first, so a consumer can override a plugin without picking a priority. The priorities are `.editor` (0, built-in fallbacks), `.low`, `.normal`, `.high`, and `.critical`, and any integer works.
- A command is its name and payload type: `Command<Int>("x")` and `Command<String>("x")` don't see each other's runs.
- Handlers registered or removed during a run take effect from the next run.

### Undo

Undo uses the native `UndoManager`, so ⌘Z, the Edit menu, and shake-to-undo work as users expect. Changesets are coalesced into undo groups (consecutive typing becomes one group). Composer does not keep its own undo stack.

Details decided in milestone 4:

- The controller registers undo with an `UndoRegistrar`, a main-actor protocol. `UndoManager` conforms on Apple platforms. Linux Foundation has no `UndoManager`, so `ComposerTesting` has `UndoStack` for Core tests. Engines set their view's undo manager.
- An undo group restores a snapshot of the state before it as the smallest edit, and registers the reverse, so undo and redo alternate. Restoring runs no transforms, so undoing a transform's rewrite doesn't redo it.
- Typing one character at the caret where the previous typing ended joins its group. Anything else (a newline, paste, deletion, a caret move) starts a new group. An IME composition is one group, registered when it ends.
- Setting the selection outside the marked text commits the composition, as a click does in a text view, and the selection is clamped to the document.

### IME and marked text

Transforms and input rules are paused while marked text exists, and they run when the composition is committed. Rewriting text under an active composition breaks Japanese, Chinese, and Korean input as well as dictation.

### Single user

There is no collaborative editing, so there are no ProseMirror-style steps and no position mapping. One thing needs a stable range across edits: a suggestion query that is waiting on an async source. The trigger plugin tracks that range itself.

## Serialization

### Markdown

Markdown is the interchange format, because apps store markdown strings. The dialect is GFM.

**Lossless means semantic, not byte for byte:**

- `parse(serialize(doc)) == doc` for every document in canonical form (see **Canonical form** below).
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

**Canonical form** (decided in milestone 3). Some documents have no markdown spelling, so the round trip is `parse(serialize(doc)) == MarkdownCodec.canonical(doc)`, for every document whose atomic nodes are registered and that has no unknown nodes. `canonical` is `Document.normalized()` plus one schema rule, and it never changes text:

- Whitespace at the edges of bold, italic, and strikethrough moves outside the mark (`** a**` is not emphasis in CommonMark). Paragraphs don't end with a line break, empty paragraphs, quotes, and lists are removed, adjacent runs with the same marks merge, and line endings are `\n`.
- A list inside a quote starts counting levels again. Quotes nest at most 8 deep; deeper quotes are spliced into their parent. Ordered starts are clamped to `0...999_999_999`, the nine digits CommonMark allows.
- Next to a custom-syntax token whose markdown ends (or starts) with a word character, such as `#tag`, there is no character left to escape, so emphasis can open (or close) there only before one word character, with a single delimiter. Otherwise the emphasis moves off the edge character. This is rare (`#tag*(x)*`) and keeps the text.

Other dialect decisions:

- Export writes the minimal escaping and checks it by parsing the paragraph back; if that fails, it escapes all punctuation in the paragraph instead. Adversarial input sometimes takes the fallback.
- A newline in a paragraph exports as a line ending, and an empty line as a `\` hard break.
- Bare URLs stay text in the document. Linking them is the autolink plugin's job, while typing and on paste. `<scheme:…>` autolinks are parsed. Email autolinks, link titles, reference links, thematic breaks, setext headings, and raw HTML are unsupported, so they stay literal. Indented code is a code block, as in CommonMark.
- Character references: numeric ones and `&amp;`, `&lt;`, `&gt;`, `&quot;`, `&apos;`, and `&nbsp;` decode. Other named references stay literal, so the parser needs no entity table.
- Hostile input is bounded: containers nest at most 32 deep while parsing, and deeper markers stay text.

### Directives and node codecs

Codecs are configured per node type, and each has a default:

- Atomic nodes (mentions, custom tokens, slash tokens) default to generic directives, for example `:mention[tom]{#user_123}`. Directives are a CommonMark *proposal* implemented by `remark-directive`. They are not part of the CommonMark spec or GFM. They are the default because they are generic: they carry a type, a label, and attributes without app-specific syntax, and JS clients can parse them with an existing library. Because they are not standard, the codec can be replaced.
- Hashtags default to plain `#tag`, which every markdown renderer already shows sensibly.
- A directive parses only when its name is registered; others stay literal text. As in `remark-directive`, a directive doesn't start right after a `:`, so export writes such a colon as `&#58;`. Attributes are written `#id` when the id is a plain identifier, and `key="value"` otherwise. Keys that aren't attribute names can't be written, so markdown drops them (JSON keeps them).
- A custom codec gives its trigger characters, an encoder, and a decoder that reads from a trigger. Export escapes a trigger wherever the decoder would accept the text after it.

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
- The field names (decided in milestone 3): blocks are `paragraph` and `quote` with `children`, `codeBlock` with `text` and `attrs.language`, and `list` with `attrs.kind` (`bullet` or `ordered`), `attrs.start`, and `listItem` children with an optional `attrs.checked`. A text node has `text`, `marks` (`bold`, `italic`, `strikethrough`, `code`), and `attrs.href` for a link. An atomic node has `type`, `text`, `label`, and its attributes in `attrs` as strings. `label` is a top-level field rather than an attribute so it can't collide with one.
- A `version` other than 1 throws. `Document`'s own `Codable` conformance is the schema-free form, so every atomic node decodes as unknown; `JSONCodec(schema:)` keeps typed nodes.
- A node whose type has no registered plugin decodes to an opaque `UnknownNode`. It keeps its JSON verbatim, renders and exports to markdown as its `text`, and encodes back to the same JSON. If `text` is missing, as in hand-written JSON, the node renders as `[type]`, for example `[poll]`, and its JSON is still kept verbatim. A composer configured with fewer plugins than the one that wrote a draft therefore never destroys content. "Verbatim" is up to number formatting: integers and doubles keep their value, not their spelling.

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

Details decided in milestone 4 (the AppKit engine, shared through `ComposerTextKit`):

- **Text storage mirrors the linear form one character per unit**, so a document position is a storage offset and nothing maps between them. Text blocks are separated by `\n`, and a newline inside a paragraph or code block is `\n` too, so each line is a TextKit paragraph. Each line's characters, and the newline after it, carry the paragraph style and a decoration naming the block's containers and whether the line is the block's first or last; only the last line has the space after the block. A custom `NSTextLayoutFragment` draws the decoration: list markers and task boxes on a block's first line, quote bars, and code backgrounds, all in the indent and taking no characters. Why not one TextKit paragraph per block, with line breaks as U+2028: TextKit 2 lays out a paragraph whole, and a 20k-character pasted block took 2.4 s to lay out that way, against 25 ms as separate paragraphs.
- **Tokens render as one attachment character (U+FFFC)**, drawn as the node's fallback text on a rounded background, until token rendering lands with the trigger plugins (milestone 7). Rendering a token as a styled text run, as [Token rendering](#token-rendering) intends, makes it several storage characters for one document unit, so it needs an offset map in the engine; that map is milestone 7's to add, together with `TokenStyle`.
- **The text view never edits its own text.** `insertText`, marked text, key presses, editing commands, paste, and every other change AppKit proposes through `shouldChangeText` (drops, spelling corrections, word and line deletion, services) become controller input, and the view returns `false` and applies the update's changeset instead. That keeps one editing path for every engine and for Core tests.
- **Changesets apply as one replacement**: `Changeset.combinedEdit` folds the sequential edits into the span they cover, and the applier replaces only that span of `NSTextStorage`. When the edit adds or removes a newline or spans blocks, the span grows to whole blocks, because which lines are first and last changes, and on through the following blocks inside containers, because inserting or removing a list item renumbers the items after it.
- **Marked text** lives in the document, and the view reports it through `hasMarkedText` and `markedRange`. Its styling is not in the storage, which still mirrors the document: `NSTextView` draws its own marked-text highlight from `markedRange`, and on iOS the view adds a tinted background as a TextKit rendering attribute, since UIKit draws nothing for marked text it doesn't own.
- **Keys:** `keyDown` gives ↩, ⇥, ⌫, and ⌦ to `ComposerController.handleKeyPress` (the keymap, then the default action) before AppKit's key bindings, and other keys to the keymap; unhandled keys go to AppKit (caret movement, word deletion, the input method). Unhandled ↩ and ⇥ combinations do nothing rather than inserting text. ⌘ and ⌃ combinations try the keymap in `performKeyEquivalent`, before menus. While marked text exists, every key goes to the input method. Editing selectors that reach `doCommand(by:)` (from key bindings such as ⌃H, or from input methods) run as the keys they stand for, and `complete:` does nothing, since suggestions are plugins.
- **Selection direction:** AppKit doesn't say which end of a selection moves. A change made from the keyboard that keeps one end of the previous selection keeps it as the anchor (⇧← makes a backward selection); other selections run forward.
- **Copy** writes plain text for now, with tokens as their labels. The three representations in [Copy](#copy) come with the clipboard work.

Details decided in milestone 5 (the UIKit engine, on the same `ComposerTextKit` mapping and applier):

- **Input** comes through `UITextInput` as the keyboard calls it: `insertText`, `deleteBackward`, `setMarkedText`, `unmarkText`, and `replace(_:withText:)` (autocorrection, the candidate bar, dictation) go to the controller. The keyboard's Return and Tab arrive as `insertText("\n")` and `insertText("\t")` and run as those keys, the keymap first. The view is its own `UITextViewDelegate`, which turns any other edit UIKit proposes (drops, Writing Tools) into input and reports every selection change.
- **The input system is told about changes it didn't ask for** (`inputDelegate` `textWillChange`/`textDidChange` and the selection equivalents) around every changeset applied outside a keyboard call, such as a transform on paste or an undo, so autocorrection and composition stay in step.
- **Hardware keys** are `UIKeyCommand`s built from the keymap each time UIKit asks, with discoverability titles for the iPad shortcut overlay, plus ⇧↩ (a line break) and ⌦. Bindings on unmodified printable keys are left to typing. A command applies (`canPerformAction`) only while a binding for its key applies in the current state, so ↑ falls through to UIKit's caret movement unless, say, suggestions are open. A selection change inside `pressesBegan` counts as from the keyboard for selection direction.
- **Undo** registers with an `UndoManager` the view owns, not `UITextView`'s, which collects UIKit's own text-editing registrations.
- **The keyboard accessory slot** is `ComposerTextView.keyboardAccessoryView`, the view's `inputAccessoryView`, reloaded while focused. The slot as data on the controller comes with the other slots.
- **No platform differences yet.** Both engines do the same thing for every key the conformance suite presses: ↩ makes a new block on both until the Return and send rules in [Return](#return) land with their plugin, so the conformance allowlist is still empty.

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

Details decided in milestone 6:

- **Observation is narrow by construction.** `ComposerController.state` changes with every keystroke and selection change, so only views that show the text or selection read it, such as `Composer.Footer`, whose content gets the state. The controller also has `isEmpty` and `isFocused`, observed on their own, so `Composer.Placeholder` changes only when the document empties or fills. `Composer.Input` reads nothing observable: the text view applies each changeset itself, and SwiftUI hears from it only when its fitting height changes. `ComposerSwiftUITests` hosts a composer in a window and checks that typing and selection changes re-render the footer and nothing else (not the root, a sibling, the placeholder, or the input's representable).
- **Height:** both `ComposerTextView`s have `lineLimits` and `fittingHeight`: the text's height clamped to that many lines of the base font, plus the insets, with layout stopping at the upper limit. It is their intrinsic height, cached by width and invalidated only when an edit or a new width changes it. The representables answer `sizeThatFits` with the offered width and that height. While `isExpanded` is true, the input takes all the height it is offered instead. `Composer.Input` doesn't set `isExpanded`; the app does, from its own control or gesture. Sizing settles: once laid out, further layout passes don't size the input again (tested). On iOS, text that fits never scrolls, so the first line doesn't stay hidden after the view grows.
- **Focus:** `.focused($focus)` on `Composer.Input` works through SwiftUI's first-responder bridging for representables, in both directions, on macOS and the iOS Simulator (tested). The engines also report focus as `ComposerController.isFocused`, for UIKit and AppKit consumers.
- **Placeholder:** `Composer.Input("Message")` uses the text view's own `placeholder`, drawn at the text's origin and hidden while the document has content. The `Composer.Placeholder` slot is for anything else.
- **Slots that land now:** `Composer.Root` (the controller in the environment; no layout of its own), `Composer.Input`, `Composer.Placeholder`, `Composer.Footer`, and, on iOS, `.composerKeyboardAccessory { … }`, hosted in a `UIHostingController` as the text view's `inputAccessoryView`. Header, Attachments, Actions, Suggestions, and SelectionToolbar land with the data they show (milestones 7 and 8).
- **Styles:** `ComposerActionStyle`, `SuggestionItemStyle`, and `AttachmentStyle`, each with its configuration, a default style, an environment value, a modifier, and a view that renders a configuration with the environment's style (`Composer.StyledAction`, …). The views that use them come with their slots. `.composerTextStyle(for:)` comes with `TokenStyle` in milestone 7.

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

Core is Foundation-only, so the keymap uses its own `Key` and `KeyModifiers` rather than SwiftUI's `KeyEquivalent` and `EventModifiers`. The native layers map them. `discoverabilityTitle` is a `LocalizedStringResource` on Apple platforms and a `String` on Linux, where Foundation has no `LocalizedStringResource`. A key press tries the bindings whose `when` holds, in priority order (the most recently added first among equals), until one's command is handled.

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
| `ComposerSwiftUITests` | macOS, iOS sim | the SwiftUI binding hosted in a window: invalidation, sizing, focus |
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

Conformance details decided in milestone 4:

- A step is `Type` (characters one at a time, through the text input client; a newline is a press of ↩), `Marked(stages…, committing:)` (each stage becomes the marked text, then the commit replaces it, or `nil` leaves the composition open), `Press(key, modifiers:)` (a key event; not `Key`, which is Core's key type), `Paste`, `Select` (forward only, since text views don't expose direction), `Undo`, and `Redo`.
- `ControllerDriver` is the reference: it sends steps straight to the controller, with ← and → moving by character or node as text views do. The native drivers run the same steps on a real text view in an offscreen window. `AppKitDriver` sends typing and marked text through the text input client methods and keys as key events. `UIKitDriver` sends typing, Return, Tab, ⌫, and marked text through the `UITextInput` methods the keyboard calls, other keys through the view's key commands, and ← and → as UIKit moves the caret, by the text input tokenizer's characters. `NativeDriver` names the platform's driver, so one suite runs on both. `firstDivergence` compares the two after every step and reports the first step where the states differ, or where the engine's text storage differs from a fresh rendering of the document, which is what catches applier bugs. The allowlist is a list of named normalizations applied to both states; it is empty until the platform-specific Return and send rules land with their plugins.

### Performance

Budgets are measured in CI against the native views:

| Scenario            | Budget                              |
| ------------------- | ----------------------------------- |
| Keystroke           | < 4 ms of main-thread work          |
| 20k-character paste | no visible hitch                    |
| Mount               | < 5 ms                              |

The workload is chat-sized: usually under 2k characters, with pastes of up to about 20k. The design does not optimize for book-length documents.

How they are measured (decided in milestone 4): the keystroke budget applies to the median, over 300 characters typed through `insertText` into the middle of a 2k-character mixed document (the 95th percentile gets twice the budget, for scheduling noise on shared CI machines), of the update, transforms, the changeset applied to text storage, and layout of the viewport. "No visible hitch" for a 20k-character paste is taken as a median under 100 ms through viewport layout, the limit for a response to feel immediate; a paste is a one-off event, so one frame (16 ms) is not the bar. Mount is the median time to create a composer, add its text view to a window, and lay out its viewport, after warm-up, for an empty composer and for one restoring a short draft, as a chat screen mounts its input. With a 2k-character document, TextKit's layout dominates: on the CI runners a plain TextKit 2 `NSTextView` showing the same text takes about 11 ms, so that case is checked against that floor rather than against 5 ms: measured interleaved with the plain view, the composer stays within 1.5 times it plus 2 ms (it also maps the document, which the plain view is handed). Shared CI machines vary by about 2× from run to run, so this is a guard against regressions, not a budget. The performance tests run in their own CI step, after the other tests, so parallel tests don't skew them.

On the iOS Simulator (decided in milestone 5, and accepted), a plain TextKit 2 `UITextView` doing the same work misses some budgets on the shared CI machines: its keystroke p95 is around 14 ms, and an empty mount takes around 3 ms, against 0.4 ms on macOS. So on the simulator each budget applies only where the plain view can meet it; otherwise the composer must stay within 1.5 times the plain view, plus 2 ms, measured interleaved with it in the same run. macOS keeps the absolute budgets. The budgets are for devices, and the composer has not been measured on one yet.

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

Questions found during implementation go here until they are decided. The decision then moves into the relevant section.

None open.
