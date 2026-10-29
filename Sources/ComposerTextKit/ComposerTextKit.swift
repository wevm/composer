// TextKit 2 code shared by the UIKit and AppKit engines: layout fragments,
// attribute mapping, and the changeset applier. Internal to the package, and
// empty on Linux.
#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif
