# VoiceOver — UIKit

## Contents
- [Core UIAccessibility Properties](#core-uiaccessibility-properties)
- [UIAccessibilityTraits Reference](#uiaccessibilitytraits-reference)
- [UIAccessibilityElement - Custom Elements](#uiaccessibilityelement---custom-elements)
- [UIAccessibilityContainer - Element Ordering](#uiaccessibilitycontainer---element-ordering)
- [UIAccessibilityCustomAction - Custom Actions](#uiaccessibilitycustomaction---custom-actions)
- [UIAccessibilityCustomRotor - Custom Navigation](#uiaccessibilitycustomrotor---custom-navigation)
- [Notifications - Announcements and Focus](#notifications---announcements-and-focus)
- [UIAccessibilityReadingContent](#uiaccessibilityreadingcontent)
- [Modal Views](#modal-views)
- [Custom Control Patterns](#custom-control-patterns)
- [NSAttributedString Accessibility Attributes](#nsattributedstring-accessibility-attributes)
- [Common Mistakes](#common-mistakes)

---

## Core UIAccessibility Properties

Every `UIView` subclass exposes these properties. Override them to provide accessibility information.

```swift
class RatingView: UIView {
    var rating: Int = 0 {
        didSet {
            // Notify VoiceOver that value changed
            UIAccessibility.post(notification: .layoutChanged, argument: self)
        }
    }

    // REQUIRED: opt this view into the accessibility tree
    override var isAccessibilityElement: Bool {
        get { true }
        set { }
    }

    override var accessibilityLabel: String? {
        get { "Rating" }
        set { }
    }

    override var accessibilityValue: String? {
        get { "\(rating) out of 5 stars" }
        set { }
    }

    override var accessibilityHint: String? {
        get { "Double-tap and hold, then swipe up or down to change" }
        set { }
    }

    override var accessibilityTraits: UIAccessibilityTraits {
        get { .adjustable }
        set { }
    }

    // Support increment/decrement gestures (VoiceOver swipe up/down)
    override func accessibilityIncrement() {
        rating = min(5, rating + 1)
    }

    override func accessibilityDecrement() {
        rating = max(0, rating - 1)
    }
}
```

### Key Properties

| Property | Type | Purpose |
|---|---|---|
| `isAccessibilityElement` | `Bool` | Opt view into accessibility tree |
| `accessibilityLabel` | `String?` | Announced name (required for non-text elements) |
| `accessibilityHint` | `String?` | Describes the result of activating |
| `accessibilityValue` | `String?` | Current value (sliders, progress) |
| `accessibilityTraits` | `UIAccessibilityTraits` | Semantic role and state |
| `accessibilityFrame` | `CGRect` | Accessibility hit area (in screen coordinates) |
| `accessibilityPath` | `UIBezierPath?` | Custom non-rectangular hit area |
| `accessibilityActivationPoint` | `CGPoint` | Precise tap point |
| `accessibilityViewIsModal` | `Bool` | Constrain VoiceOver focus to this view |
| `shouldGroupAccessibilityChildren` | `Bool` | Group children for scanning |
| `accessibilityNavigationStyle` | `UIAccessibilityNavigationStyle` | `.automatic` / `.combined` / `.separate` |
| `accessibilityCustomActions` | `[UIAccessibilityCustomAction]?` | Custom action list |
| `accessibilityCustomRotors` | `[UIAccessibilityCustomRotor]?` | Custom rotor navigation |
| `accessibilityContainerType` | `UIAccessibilityContainerType` | `.none` / `.list` / `.landmark` / `.semanticGroup` / `.table` / `.dataTable` |

### `accessibilityFrame` — Custom Hit Area

By default, `accessibilityFrame` matches the view's frame in screen coordinates. Override when the visual and accessible areas differ.

```swift
override var accessibilityFrame: CGRect {
    // Convert to screen coordinates
    return UIAccessibility.convertToScreenCoordinates(bounds, in: self)
}

// Extend hit area to 44pt minimum
override var accessibilityFrame: CGRect {
    let frame = convert(bounds, to: nil)
    let minSize: CGFloat = 44
    let expandX = max(0, (minSize - frame.width) / 2)
    let expandY = max(0, (minSize - frame.height) / 2)
    return frame.insetBy(dx: -expandX, dy: -expandY)
}
```

---

## UIAccessibilityTraits Reference

Traits can be combined with `|` (union).

```swift
accessibilityTraits = [.button, .selected]
```

| Trait | When to Use |
|---|---|
| `.button` | Any tappable element that isn't a `UIButton` |
| `.link` | Opens a URL or navigates outside the app |
| `.header` | Section or page header |
| `.selected` | Currently selected item |
| `.image` | Image view (decorative or informational) |
| `.searchField` | Search text field |
| `.playsSound` | Activation plays audio |
| `.keyboardKey` | Custom keyboard key |
| `.staticText` | Non-interactive display text |
| `.summaryElement` | Spoken when app first launches |
| `.notEnabled` | Disabled/unavailable control |
| `.updatesFrequently` | Live region — re-read on value change |
| `.startsMediaSession` | Starts audio/video playback |
| `.adjustable` | Supports increment/decrement |
| `.allowsDirectInteraction` | Passes raw touches (piano keys, drawing) |
| `.causesPageTurn` | Triggers a page turn in reading apps |
| `.tabBar` | Tab bar (system-handled) |

### State via Traits

```swift
// ✅ Selected state as trait
cell.accessibilityTraits = isSelected ? [.button, .selected] : .button

// ❌ State embedded in label (breaks automation and is verbose)
cell.accessibilityLabel = isSelected ? "Photos, selected" : "Photos"
```

---

## UIAccessibilityElement - Custom Elements

Use when content is drawn in a custom view (`drawRect`, Core Graphics, Metal) with no native subviews. `UIAccessibilityElement` creates virtual elements over the custom-drawn content.

```swift
class GraphView: UIView {
    var bars: [BarData] = []

    // Cache elements — recreate when data changes
    private var _accessibilityElements: [UIAccessibilityElement]?

    override var isAccessibilityElement: Bool {
        get { false }   // Container itself is NOT an element
        set { }
    }

    override var accessibilityElements: [Any]? {
        get {
            if _accessibilityElements == nil {
                _accessibilityElements = bars.enumerated().map { index, bar in
                    let element = UIAccessibilityElement(accessibilityContainer: self)
                    element.accessibilityLabel = bar.label
                    element.accessibilityValue = "\(bar.value) units"
                    element.accessibilityTraits = .staticText
                    // Convert bar's CGRect to screen coordinates
                    let barFrame = frameForBar(at: index)
                    element.accessibilityFrame = UIAccessibility.convertToScreenCoordinates(barFrame, in: self)
                    return element
                }
            }
            return _accessibilityElements
        }
        set { _accessibilityElements = newValue as? [UIAccessibilityElement] }
    }

    func dataDidChange() {
        _accessibilityElements = nil
        // Tell VoiceOver the layout changed
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }
}
```

---

## UIAccessibilityContainer - Element Ordering

When a view contains multiple subviews that should be navigated in a specific order, implement `UIAccessibilityContainer` by providing `accessibilityElements`.

```swift
class DashboardView: UIView {
    @IBOutlet var headerView: UIView!
    @IBOutlet var chartView: UIView!
    @IBOutlet var summaryLabel: UILabel!
    @IBOutlet var actionButton: UIButton!

    // Return elements in the desired reading order
    override var accessibilityElements: [Any]? {
        get { [headerView!, summaryLabel!, chartView!, actionButton!] }
        set { }
    }
}
```

### `accessibilityContainerType`

Provides semantic meaning to containers. VoiceOver announces container type changes.

```swift
tableContainerView.accessibilityContainerType = .dataTable
listView.accessibilityContainerType = .list
navContainerView.accessibilityContainerType = .landmark
```

### `shouldGroupAccessibilityChildren`

Groups all children into a single node for Switch Control scanning. Does NOT merge for VoiceOver navigation.

```swift
groupView.shouldGroupAccessibilityChildren = true
```

---

## UIAccessibilityCustomAction - Custom Actions

Adds entries to VoiceOver's Actions rotor (double-tap and hold → swipe up/down). Essential for swipe-to-reveal and long-press menus.

```swift
class MessageCell: UITableViewCell {
    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            [
                UIAccessibilityCustomAction(name: "Reply", target: self, selector: #selector(reply)),
                UIAccessibilityCustomAction(name: "Forward", target: self, selector: #selector(forward)),
                UIAccessibilityCustomAction(name: "Delete", image: UIImage(systemName: "trash")) { [weak self] _ in
                    self?.deleteMessage()
                    return true
                }
            ]
        }
        set { }
    }

    @objc private func reply() -> Bool {
        replyToMessage()
        return true  // return true = action succeeded
    }

    @objc private func forward() -> Bool {
        forwardMessage()
        return true
    }
}
```

**Return value:** Return `true` if the action was performed, `false` if not applicable.

---

## UIAccessibilityCustomRotor - Custom Navigation

Creates new items in VoiceOver's rotor for app-specific navigation (e.g., jump between headings, unread items, errors).

```swift
class ArticleViewController: UIViewController {
    var headings: [Heading] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        accessibilityCustomRotors = [makeHeadingRotor(), makeBookmarkRotor()]
    }

    private func makeHeadingRotor() -> UIAccessibilityCustomRotor {
        UIAccessibilityCustomRotor(name: "Headings") { [weak self] predicate in
            guard let self = self else { return nil }

            let currentIndex = self.headings.firstIndex { $0.view == predicate.currentItem.targetElement as? UIView }
            let nextIndex: Int

            switch predicate.searchDirection {
            case .next:
                nextIndex = (currentIndex.map { $0 + 1 }) ?? 0
            case .previous:
                nextIndex = currentIndex.map { $0 - 1 } ?? self.headings.count - 1
            @unknown default:
                return nil
            }

            guard nextIndex >= 0, nextIndex < self.headings.count else { return nil }
            let heading = self.headings[nextIndex]
            return UIAccessibilityCustomRotorItemResult(targetElement: heading.view, targetRange: nil)
        }
    }
}
```

---

## Notifications - Announcements and Focus

### Post an Announcement

```swift
// Simple string announcement
UIAccessibility.post(notification: .announcement, argument: "Message sent")

// Attributed string for priority control (iOS 17+)
let announcement = NSAttributedString(
    string: "Emergency alert",
    attributes: [.accessibilitySpeechQueueAnnouncement: true]
)
UIAccessibility.post(notification: .announcement, argument: announcement)
```

### Screen Changed — Full Focus Reset

Post when the entire screen content changes (e.g., modal presented, tab switched).

```swift
// Focus moves to the first element
UIAccessibility.post(notification: .screenChanged, argument: nil)

// Focus moves to a specific view
UIAccessibility.post(notification: .screenChanged, argument: confirmButton)
```

### Layout Changed — Partial Update

Post when part of the layout changes (section expands, items load, error appears).

```swift
UIAccessibility.post(notification: .layoutChanged, argument: errorLabel)
```

### Page Scrolled

```swift
UIAccessibility.post(notification: .pageScrolled, argument: "Page 3 of 10")
```

### Observing Status Changes

```swift
NotificationCenter.default.addObserver(
    self,
    selector: #selector(voiceOverStatusChanged),
    name: UIAccessibility.voiceOverStatusDidChangeNotification,
    object: nil
)

@objc func voiceOverStatusChanged() {
    // Update UI if needed — but avoid branching core logic on VoiceOver status
}
```

---

## UIAccessibilityReadingContent

For views that display long-form text (e-book readers, document viewers). Enables VoiceOver's "Read All" and line-by-line navigation.

```swift
class BookPageView: UIView, UIAccessibilityReadingContent {
    var lines: [String] = []

    func accessibilityLineNumber(for point: CGPoint) -> Int {
        return lineIndex(for: point)
    }

    func accessibilityContent(forLineNumber lineNumber: Int) -> String? {
        guard lineNumber < lines.count else { return nil }
        return lines[lineNumber]
    }

    func accessibilityFrame(forLineNumber lineNumber: Int) -> CGRect {
        return UIAccessibility.convertToScreenCoordinates(
            frameForLine(lineNumber), in: self
        )
    }

    func accessibilityPageContent() -> String? {
        return lines.joined(separator: " ")
    }
}
```

---

## Modal Views

When a modal or alert is presented, VoiceOver must be prevented from reaching background content.

```swift
class ModalView: UIView {
    override var accessibilityViewIsModal: Bool {
        get { true }
        set { }
    }
}

// When presenting:
func presentModal() {
    let modal = ModalView()
    view.addSubview(modal)
    // VoiceOver now ignores everything behind modal
    UIAccessibility.post(notification: .screenChanged, argument: modal.firstInteractiveElement)
}

// Support Escape to dismiss (VO two-finger Z)
override func accessibilityPerformEscape() -> Bool {
    dismiss()
    return true
}
```

---

## Custom Control Patterns

### Toggle / Checkbox

```swift
class AccessibleCheckbox: UIControl {
    var isChecked: Bool = false {
        didSet { accessibilityValue = isChecked ? "On" : "Off" }
    }

    override var isAccessibilityElement: Bool { get { true } set {} }
    override var accessibilityLabel: String? { get { title } set {} }
    override var accessibilityTraits: UIAccessibilityTraits {
        get { isChecked ? [.button, .selected] : .button }
        set {}
    }

    // Or use .toggleButton trait (iOS 17+)
}
```

### Custom Slider

```swift
class CustomSlider: UIView {
    var value: Float = 0.5
    var minValue: Float = 0
    var maxValue: Float = 1

    override var accessibilityTraits: UIAccessibilityTraits { get { .adjustable } set {} }
    override var accessibilityValue: String? {
        get { "\(Int(value * 100)) percent" }
        set {}
    }

    override func accessibilityIncrement() {
        value = min(maxValue, value + 0.05)
        UIAccessibility.post(notification: .layoutChanged, argument: self)
    }

    override func accessibilityDecrement() {
        value = max(minValue, value - 0.05)
        UIAccessibility.post(notification: .layoutChanged, argument: self)
    }
}
```

### `accessibilityActivate()` — Custom Activation

Called when VoiceOver user double-taps. Useful when the normal tap behavior differs from the accessibility action.

```swift
override func accessibilityActivate() -> Bool {
    // Show expanded detail view instead of just toggling
    showDetailPanel()
    return true  // true = handled, false = pass to normal tap handler
}
```

---

## NSAttributedString Accessibility Attributes

Apply per-character accessibility attributes for rich text.

```swift
let string = NSMutableAttributedString(string: "Error: Invalid password")
string.addAttributes([
    .accessibilitySpeechPitch: 0.5,               // lower pitch
    .accessibilitySpeechQueueAnnouncement: true,   // queue, don't interrupt
    .accessibilitySpeechSpellOut: false,
    .accessibilitySpeechLanguage: "en-US"
], range: NSRange(location: 0, length: string.length))

label.attributedText = string
```

---

## Common Mistakes

| Mistake | Fix |
|---|---|
| Container `isAccessibilityElement = true` alongside `accessibilityElements` | Set `isAccessibilityElement = false` on containers that expose children |
| `accessibilityFrame` in local coordinates | Always convert: `UIAccessibility.convertToScreenCoordinates(rect, in: view)` |
| Forgetting to invalidate cached `accessibilityElements` | Nil out cache and post `.layoutChanged` when data changes |
| Missing `accessibilityIncrement`/`Decrement` on `.adjustable` trait | `.adjustable` trait requires both methods |
| No `accessibilityPerformEscape()` on custom modals | Implement to support two-finger Z gesture and Escape key |
| Using `notification: .screenChanged` for partial updates | Use `.layoutChanged` for partial; `.screenChanged` for full screen replacement |
| `accessibilityViewIsModal` on wrong view | Set on the outermost modal view, not a child |
| No announcement after async state change | Post `.layoutChanged` or `.announcement` after network/async operations complete |
| Labels in `UIAccessibilityElement` not updated after layout change | Rebuild elements array and nil cache when bounds change |
