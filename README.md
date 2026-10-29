# Composer

A native rich-text message composer for iOS and macOS: headless and
plugin-based, with SwiftUI, UIKit, and AppKit layers over one
`@Observable` controller. Messages go in and out as markdown.

> [!WARNING]
> Alpha, and not usable yet: this is the package's scaffolding. Releases are
> `0.0.x`, with no API stability promise.

## Requirements

- Swift 6.2
- iOS 26 or macOS 26. `ComposerCore` and the pure part of `ComposerTesting`
  also build on Linux.

## Products

| Product           | Contents                                                      |
| ----------------- | ------------------------------------------------------------- |
| `ComposerCore`    | The document model, codecs, plugins, and `ComposerController` |
| `ComposerUIKit`   | The UIKit engine                                              |
| `ComposerAppKit`  | The AppKit engine                                             |
| `ComposerSwiftUI` | Representables and the `Composer.Root`, `Composer.Input`, … primitives |
| `ComposerStyled`  | The reference design                                          |
| `ComposerTesting` | The conformance harness                                       |

## Development

```sh
swift build --build-tests
swift test
swift format lint --strict --recursive Sources Tests Package.swift Playground
```

The Playground is an iOS and macOS app. Generate its Xcode project with
XcodeGen (`brew install xcodegen`): `cd Playground && xcodegen generate`,
then open `Playground.xcodeproj`.

To release, bump `VERSION` on `main`; CI tags it and creates the GitHub
release.

[`DESIGN.md`](DESIGN.md) explains the design and the milestones.

## License

MIT
