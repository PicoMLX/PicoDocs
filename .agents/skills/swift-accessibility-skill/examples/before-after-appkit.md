# Before/After: AppKit Accessibility

Concrete code transformations for macOS AppKit apps. Each example shows the inaccessible version, the corrected version, and a summary of every change.

Priority tiers:
- **Blocks Assistive Tech** — Element is completely unreachable or unusable
- **Degrades Experience** — Reachable with significant friction
- **Incomplete Support** — Gaps that prevent Nutrition Label claims

## Contents

### Blocks Assistive Tech
- Icon-only NSButton missing label
- Custom NSView not in accessibility tree
- NSTableView row without accessible summary

### Degrades Experience
- Keyboard focus missing on custom view
- Context menu without keyboard equivalent
- Wrong role on custom control

### Incomplete Support
- Hardcoded font sizes (no Dynamic Type)
- Color-only status in NSTableView cell

---

## [Blocks Assistive Tech] Icon-only NSButton missing label

**Problem:** VoiceOver announces "button" with no description. The user cannot tell what the button does.
This commonly happens with icon-only controls backed by custom assets when you rely on visuals alone.

```swift
// ❌ Before
let shareButton = NSButton()
shareButton.image = NSImage(named: "share")
shareButton.imageScaling = .scaleProportionallyDown
shareButton.isBordered = false
shareButton.bezelStyle = .toolbar
```

```swift
// ✅ After
let shareButton = NSButton()
shareButton.image = NSImage(named: "share")
shareButton.imageScaling = .scaleProportionallyDown
shareButton.isBordered = false
shareButton.bezelStyle = .toolbar
shareButton.setAccessibilityLabel("Share") // [VERIFY] confirm label matches intent
shareButton.toolTip = "Share"
```

**Changes:**
| Change | Why |
|---|---|
| Kept the same icon-only visual in both versions | Isolates the accessibility delta to semantic labeling, not visuals |
| Added `setAccessibilityLabel("Share")` | Aligns with AppKit guidance: the control, not its decorative image, owns the semantic label |
| Kept custom image asset unchanged | Ensures the improvement comes from semantics, not image substitution |
| Added `toolTip` | Improves discoverability for sighted keyboard and pointer users |

---

## [Blocks Assistive Tech] Custom NSView not in accessibility tree

**Problem:** A custom-drawn card view exists visually but VoiceOver cannot reach it at all.

```swift
// ❌ Before
class ProjectCardView: NSView {
    var title: String = ""
    var status: String = ""

    override func draw(_ dirtyRect: NSRect) {
        // Custom drawing...
    }
}
```

```swift
// ✅ After
class ProjectCardView: NSView {
    var title: String = "" {
        didSet { updateAccessibility() }
    }
    var status: String = "" {
        didSet { updateAccessibility() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        updateAccessibility()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        updateAccessibility()
    }

    private func updateAccessibility() {
        setAccessibilityLabel("\(title), \(status)")
    }

    override func draw(_ dirtyRect: NSRect) {
        // Custom drawing...
    }
}
```

**Changes:**
| Change | Why |
|---|---|
| Added `setAccessibilityElement(true)` | Exposes the custom-drawn view to the accessibility tree |
| Added `setAccessibilityRole(.group)` | Announces semantic container role instead of generic unlabeled content |
| Added `updateAccessibility()` and property observers | Keeps label synchronized as title/status change |

---

## [Blocks Assistive Tech] NSTableView row without accessible summary

**Problem:** VoiceOver reads individual cells but cannot summarize the row. Users hear fragmented information with no context.

```swift
// ❌ Before
class TaskRowView: NSTableRowView {
    var taskName: String = ""
    var assignee: String = ""
    var dueDate: String = ""
}
```

```swift
// ✅ After
class TaskRowView: NSTableRowView {
    var taskName: String = "" {
        didSet { updateAccessibility() }
    }
    var assignee: String = "" {
        didSet { updateAccessibility() }
    }
    var dueDate: String = "" {
        didSet { updateAccessibility() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        updateAccessibility()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setAccessibilityElement(true)
        updateAccessibility()
    }

    private func updateAccessibility() {
        setAccessibilityLabel(taskName)
        setAccessibilityValue("Assigned to \(assignee), due \(dueDate)")
    }
}
```

**Changes:**
| Change | Why |
|---|---|
| Added `setAccessibilityElement(true)` | Ensures the row itself can expose a concise summary |
| Added `setAccessibilityLabel` | Provides a primary row name (task title) |
| Added `setAccessibilityValue` | Adds secondary context (assignee and due date) |
| Added `updateAccessibility()` in observers and initializers | Prevents stale announcements when row data updates |

---

## [Degrades Experience] Keyboard focus missing on custom view

**Problem:** A clickable card responds to mouse clicks but cannot be reached or activated via keyboard.

```swift
// ❌ Before
class ClickableCardView: NSView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
```

```swift
// ✅ After
class ClickableCardView: NSView {
    var onClick: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Project card") // [VERIFY]
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Project card") // [VERIFY]
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { // Return or Space
            onClick?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func drawFocusRingMask() {
        bounds.fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }
}
```

**Changes:**
| Change | Why |
|---|---|
| Added `acceptsFirstResponder` | Enables keyboard focus traversal |
| Added `keyDown` handling for Return/Space | Supports keyboard activation parity with mouse input |
| Added focus ring overrides | Makes keyboard focus visible |
| Added accessibility role and label | Announces the custom view as an actionable control |

---

## [Degrades Experience] Context menu without keyboard equivalent

**Problem:** Right-click menu is the only way to access actions. Keyboard and VoiceOver users cannot reach them.

```swift
// ❌ Before
class DocumentView: NSView {
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Duplicate", action: #selector(duplicateDocument), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Delete", action: #selector(deleteDocument), keyEquivalent: ""))
        return menu
    }
}
```

```swift
// ✅ After
class DocumentView: NSView {
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let duplicateItem = NSMenuItem(title: "Duplicate", action: #selector(duplicateDocument), keyEquivalent: "d")
        duplicateItem.target = self
        let deleteItem = NSMenuItem(title: "Delete", action: #selector(deleteDocument), keyEquivalent: "\u{8}") // Delete key
        deleteItem.target = self
        menu.addItem(duplicateItem)
        menu.addItem(deleteItem)
        return menu
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureAccessibilityActions()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureAccessibilityActions()
    }

    private func configureAccessibilityActions() {
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(
                name: "Duplicate",
                target: self,
                selector: #selector(duplicateDocument)
            ),
            NSAccessibilityCustomAction(
                name: "Delete",
                target: self,
                selector: #selector(deleteDocument)
            )
        ])
    }

    @objc private func duplicateDocument() {
        // Duplicate document content.
    }

    @objc private func deleteDocument() {
        // Delete document content.
    }
}
```

**Changes:**
| Change | Why |
|---|---|
| Added `keyEquivalent` values | Exposes right-click actions to keyboard users |
| Added explicit menu item targets | Makes selector dispatch deterministic |
| Added `setAccessibilityCustomActions` | Exposes menu-only actions in the VoiceOver Actions rotor |
| Added selector method implementations | Keeps the after example self-contained and compilable |

---

## [Degrades Experience] Wrong role on custom control

**Problem:** A custom toggle is exposed as a generic group. VoiceOver doesn't announce it as a toggle or report its state.

```swift
// ❌ Before
class CustomToggleView: NSView {
    var isOn = false

    override func mouseDown(with event: NSEvent) {
        isOn.toggle()
        needsDisplay = true
    }
}
```

```swift
// ✅ After
class CustomToggleView: NSView {
    var isOn = false {
        didSet {
            setAccessibilityValue(isOn ? "1" : "0")
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel("Feature toggle") // [VERIFY]
        setAccessibilityValue(isOn ? "1" : "0")
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel("Feature toggle") // [VERIFY]
        setAccessibilityValue(isOn ? "1" : "0")
    }

    override func mouseDown(with event: NSEvent) {
        isOn.toggle()
    }

    override func accessibilityPerformPress() -> Bool {
        isOn.toggle()
        return true
    }
}
```

**Changes:**
| Change | Why |
|---|---|
| Added `setAccessibilityRole(.checkBox)` | Announces correct control type instead of generic group |
| Added `setAccessibilityValue` updates | Exposes on/off state for VoiceOver users |
| Added `accessibilityPerformPress()` | Enables activation from assistive technologies |
| Added `setAccessibilityLabel` | Provides a stable, human-readable control name |

---

## [Incomplete Support] Hardcoded font sizes

**Problem:** Text doesn't scale with the system Dynamic Type setting. macOS users who increase text size in System Settings see no change.

```swift
// ❌ Before
let titleLabel = NSTextField(labelWithString: "Project Name")
titleLabel.font = NSFont.systemFont(ofSize: 18, weight: .bold)

let bodyLabel = NSTextField(labelWithString: "Description")
bodyLabel.font = NSFont.systemFont(ofSize: 14)
```

```swift
// ✅ After
let titleLabel = NSTextField(labelWithString: "Project Name")
titleLabel.font = NSFont.preferredFont(forTextStyle: .headline)

let bodyLabel = NSTextField(labelWithString: "Description")
bodyLabel.font = NSFont.preferredFont(forTextStyle: .body)
```

**Changes:**
| Change | Why |
|---|---|
| Replaced `systemFont(ofSize:)` with `preferredFont(forTextStyle:)` | Uses user-preferred text styles for scalable typography |
| Used semantic styles (`.headline`, `.body`) | Preserves content hierarchy while adapting to text size preferences |

---

## [Incomplete Support] Color-only status in NSTableView cell

**Problem:** A green/red dot indicates task status. In grayscale or for color-blind users, the dots are indistinguishable.

```swift
// ❌ Before
let statusDot = NSView()
statusDot.wantsLayer = true
statusDot.layer?.backgroundColor = task.isComplete ? NSColor.green.cgColor : NSColor.red.cgColor
statusDot.layer?.cornerRadius = 5
```

```swift
// ✅ After
let statusDot = NSView()
statusDot.wantsLayer = true
statusDot.layer?.backgroundColor = task.isComplete ? NSColor.systemGreen.cgColor : NSColor.systemRed.cgColor
statusDot.layer?.cornerRadius = 5
statusDot.setAccessibilityElement(false)

let statusIcon = NSImageView()
statusIcon.image = NSImage(
    systemSymbolName: task.isComplete ? "checkmark.circle.fill" : "xmark.circle.fill",
    accessibilityDescription: nil
)
statusIcon.contentTintColor = task.isComplete ? .systemGreen : .systemRed
statusIcon.setAccessibilityLabel(task.isComplete ? "Complete" : "Incomplete")
```

**Changes:**
| Change | Why |
|---|---|
| Added icon alongside color | Differentiates status without relying on color alone |
| Switched to semantic colors (`systemGreen` / `systemRed`) | Adapts better across appearance and contrast settings |
| Hid decorative dot from accessibility | Avoids duplicate announcements |
| Added accessibility label on `NSImageView` | Announces semantic status (`Complete` / `Incomplete`) |
