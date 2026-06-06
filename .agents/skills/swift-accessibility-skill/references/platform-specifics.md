# Platform-Specific Accessibility

Accessibility APIs and behavior differ across supported platforms. This reference covers macOS, watchOS, tvOS, and visionOS — where behavior diverges from iOS patterns.

## Contents
- [macOS](#macos)
- [watchOS](#watchos)
- [tvOS](#tvos)
- [visionOS](#visionos)
- [Cross-Platform Conditional Code](#cross-platform-conditional-code)
- [Common Cross-Platform Mistakes](#common-cross-platform-mistakes)

---

## macOS

### NSAccessibility vs UIAccessibility

macOS uses `NSAccessibility` (AppKit) instead of `UIAccessibility`. SwiftUI handles most cases automatically, but AppKit code requires explicit NSAccessibility work.

### NSAccessibility Protocol

```swift
import AppKit

class CustomControl: NSView {
    // REQUIRED: Declare what this element is
    override func accessibilityRole() -> NSAccessibility.Role? {
        return .button
    }

    override func accessibilityLabel() -> String? {
        return "Share Document"
    }

    override func accessibilityHelp() -> String? {
        return "Shares the current document with other users."
    }

    override func isAccessibilityEnabled() -> Bool {
        return isEnabled
    }

    override func isAccessibilityElement() -> Bool {
        return true
    }

    override func accessibilityPerformPress() -> Bool {
        // Handle VoiceOver activation (Space/Return key)
        performAction()
        return true
    }
}
```

### NSAccessibility Role Reference

| Role | `NSAccessibility.Role` | When to Use |
|---|---|---|
| Button | `.button` | Clickable controls |
| Checkbox | `.checkBox` | Two-state toggles |
| Radio button | `.radioButton` | Mutually exclusive options |
| Text field | `.textField` | Editable text |
| Static text | `.staticText` | Non-interactive labels |
| Slider | `.slider` | Range controls |
| Progress indicator | `.progressIndicator` | Loading/progress |
| Table | `.table` | Tabular data |
| List | `.list` | Lists of items |
| Group | `.group` | Containers |
| Toolbar | `.toolbar` | Toolbars |
| Menu | `.menu` | Menus |
| Window | `.window` | Windows |

### Custom Actions on macOS

```swift
class InteractiveRow: NSView {
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        return [
            NSAccessibilityCustomAction(name: "Reply", target: self, selector: #selector(reply)),
            NSAccessibilityCustomAction(name: "Archive", target: self, selector: #selector(archive)),
            NSAccessibilityCustomAction(name: "Delete") { [weak self] in
                self?.delete()
                return true
            }
        ]
    }
}
```

### NSAccessibilityElement (Custom Elements)

For custom-drawn content (Core Graphics, Metal):

```swift
class ChartView: NSView {
    var bars: [BarData] = []

    override func isAccessibilityElement() -> Bool { false }

    override func accessibilityChildren() -> [Any]? {
        return bars.enumerated().map { index, bar in
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.staticText)
            element.setAccessibilityFrame(convert(frameForBar(at: index), to: nil))
            element.setAccessibilityLabel(bar.label)
            element.setAccessibilityValue(bar.value)
            element.setAccessibilityParent(self)
            return element
        }
    }
}
```

### Custom Rotors on macOS

```swift
class DocumentViewController: NSViewController, NSAccessibilityCustomRotorItemSearchDelegate {
    var headingViews: [NSView] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        let rotor = NSAccessibilityCustomRotor(label: "Headings", itemSearchDelegate: self)
        view.setAccessibilityCustomRotors([rotor])
    }

    func rotor(_ rotor: NSAccessibilityCustomRotor, resultFor searchParameters: NSAccessibilityCustomRotor.SearchParameters) -> NSAccessibilityCustomRotor.ItemResult? {
        // Navigate through headingViews based on searchParameters.searchDirection
        // Return nil when no more headings in that direction
        return nil
    }
}
```

### VoiceOver on macOS Differences

On macOS, VoiceOver uses a **cursor** model (not a swipe model):
- VoiceOver Cursor moves through elements with Tab, arrow keys, and VO+arrow
- Keyboard shortcuts are different from iOS swipe gestures
- QuickNav mode (VO+Q) lets users navigate without holding VO keys
- Web content uses the same VoiceOver gestures as Safari

**Keyboard navigation is first-class on macOS.** Every interactive element must be reachable by Tab and activated by Space/Return.

### Focus Ring

macOS displays a focus ring around the currently focused element. NSView provides this by default for standard controls.

```swift
// Custom view — draw focus ring manually
class FocusableView: NSView {
    override var focusRingType: NSFocusRingType {
        get { .default }
        set { }
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }
}
```

### Mac Catalyst

Mac Catalyst apps use UIKit APIs but run on macOS. Most UIAccessibility APIs work directly. Notable differences:
- `UIFocusSystem` enables keyboard navigation automatically in Catalyst
- Full Keyboard Access is always active on Mac
- Pointer / hover events differ from touch — test hover states
- `NSCursor` management for custom views

---

## watchOS

### VoiceOver on watchOS

WatchOS VoiceOver interaction model:
- **Tap** on element to select
- **Double-tap** to activate
- **Swipe up/down** to navigate (not left/right like iOS)
- **Digital Crown** rotates to change values on adjustable elements

```swift
// watchOS VoiceOver works with standard SwiftUI modifiers
// accessibilityLabel, accessibilityHint, accessibilityValue, etc.
Button("Start Workout") { startWorkout() }
    .accessibilityLabel("Start running workout")
    .accessibilityHint("Begins tracking your run")
```

### Digital Crown Accessibility

```swift
// ✅ Support Digital Crown for adjustable controls
struct VolumeControl: View {
    @State private var volume = 0.5

    var body: some View {
        Slider(value: $volume, in: 0...1)
            .accessibilityLabel("Volume")
            .accessibilityValue("\(Int(volume * 100)) percent")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: volume = min(1, volume + 0.1)
                case .decrement: volume = max(0, volume - 0.1)
                @unknown default: break
                }
            }
            .focusable()
            .digitalCrownRotation($volume, from: 0, through: 1, sensitivity: .medium)
    }
}
```

### Reduce Motion (watchOS)

```swift
import WatchKit

// watchOS equivalent of isReduceMotionEnabled
if WKAccessibilityIsReduceMotionEnabled() {
    // Disable animations
}

// Observe changes
NotificationCenter.default.addObserver(
    forName: NSNotification.Name(rawValue: WKAccessibilityReduceMotionStatusDidChange),
    object: nil,
    queue: .main
) { _ in
    updateAnimationPreferences()
}
```

### Small Screen Considerations

watchOS screens are small — especially important to test Dynamic Type:

```swift
// watchOS minimum: support 140% scaling (not 200% like iOS)
// Always test:
#Preview {
    MyWatchView()
        .environment(\.dynamicTypeSize, .xxLarge)  // watchOS max commonly used
}
```

### Complications and App Shortcuts

Complications should have descriptive labels. watchOS complication accessibility uses system accessibility:

```swift
// Complications are read by VoiceOver using their accessibilityLabel
// Ensure widget/complication text is meaningful without visual context
```

---

## tvOS

### Focus Engine

tvOS has **no pointer and no touch** — all navigation uses the Siri Remote directional pad and the Focus Engine.

Every interactive element must:
1. Be focusable (`canBecomeFocused` returns `true`)
2. Show a clear visual focus state
3. Respond to Select button (return key equivalent)
4. Handle the Menu button (= back/escape)

### Making Custom Views Focusable

```swift
// UIKit (tvOS)
class FocusableCardView: UIView {
    override var canBecomeFocused: Bool { true }

    override func didUpdateFocus(
        in context: UIFocusUpdateContext,
        with coordinator: UIFocusAnimationCoordinator
    ) {
        if context.nextFocusedView === self {
            coordinator.addCoordinatedAnimations {
                self.transform = CGAffineTransform(scaleX: 1.1, y: 1.1)
                self.layer.shadowOpacity = 0.5
                self.layer.shadowRadius = 12
            }
        } else if context.previouslyFocusedView === self {
            coordinator.addCoordinatedAnimations {
                self.transform = .identity
                self.layer.shadowOpacity = 0
            }
        }
    }
}
```

### Setting Default Focus

```swift
// UIKit — return the element that should receive focus first
override var preferredFocusEnvironments: [UIFocusEnvironment] {
    return [primaryContentButton]
}

// Deprecated — use preferredFocusEnvironments (shown above) instead
override weak var preferredFocusedView: UIView? { primaryContentButton }
```

### UIFocusGuide — Bridge Focus Gaps

When directional navigation leaves a gap (empty space between two rows of buttons), use `UIFocusGuide` to redirect focus:

```swift
let focusGuide = UIFocusGuide()
view.addLayoutGuide(focusGuide)

// Guide redirects focus to the right button when navigating from left button
focusGuide.preferredFocusEnvironments = [rightButton]

NSLayoutConstraint.activate([
    focusGuide.leadingAnchor.constraint(equalTo: leftButton.trailingAnchor),
    focusGuide.trailingAnchor.constraint(equalTo: rightButton.leadingAnchor),
    focusGuide.topAnchor.constraint(equalTo: leftButton.topAnchor),
    focusGuide.bottomAnchor.constraint(equalTo: leftButton.bottomAnchor)
])
```

### SwiftUI on tvOS

```swift
// SwiftUI Button is focusable by default on tvOS
Button("Play") { play() }
    .buttonStyle(.card)  // tvOS card style with lift animation

// Use focusable() for non-button interactive views
CustomCardView()
    .focusable()
    .onMoveCommand { direction in
        // Handle directional pad navigation within the view
        switch direction {
        case .up: navigateUp()
        case .down: navigateDown()
        case .left: navigateLeft()
        case .right: navigateRight()
        }
    }
```

### VoiceOver on tvOS

tvOS VoiceOver is similar to iOS but uses Siri Remote gestures:
- Swipe on the touch surface to navigate
- Tap to activate focused element
- All standard `accessibilityLabel`, `accessibilityHint`, `accessibilityAction` APIs apply

### Menu Button = Escape

The Siri Remote Menu button is the back/escape action. Implement `accessibilityPerformEscape()` on custom view controllers:

```swift
override func accessibilityPerformEscape() -> Bool {
    navigationController?.popViewController(animated: true)
    return true
}
```

### Debugging Focus

```
Simulator: Debug menu → View → Show Focus for Focus Engine Debug
```

---

## visionOS

### Accessibility in Spatial Computing

visionOS uses a mix of eye tracking, hand gestures, and voice input. VoiceOver on visionOS uses look + pinch to navigate.

### SwiftUI — Standard Modifiers Work

Standard SwiftUI accessibility modifiers (`.accessibilityLabel`, `.accessibilityHint`, traits, actions) apply directly to visionOS:

```swift
// ✅ Works on visionOS
RealityView { content in
    // 3D content
}
.accessibilityLabel("3D Model: Red Cube")
.accessibilityHint("Pinch to interact")
.accessibilityAddTraits(.isButton)
```

### RealityKit — AccessibilityComponent

For 3D entities in RealityKit, use `AccessibilityComponent`:

```swift
import RealityKit

// Add accessibility info to a 3D entity
var accessibilityComponent = AccessibilityComponent()
accessibilityComponent.label = "Spinning Globe"
accessibilityComponent.value = "Currently rotating"
accessibilityComponent.isAccessibilityElement = true
accessibilityComponent.traits = [.isButton]
accessibilityComponent.customActions = [
    AccessibilityCustomAction(name: "Stop rotation") { entity in
        entity.components.remove(RotationComponent.self)
        return true
    }
]
myGlobeEntity.components.set(accessibilityComponent)
```

### Hover Effects

visionOS elements highlight when the user looks at them. For custom interactive views:

```swift
// ✅ Standard hover effect — required for interactive elements
MyView()
    .hoverEffect(.lift)  // or .highlight

// Ensure VoiceOver alternative exists for look-based interaction
MyView()
    .hoverEffect(.highlight)
    .accessibilityLabel("Interactive Panel")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { performAction() }
```

### Voice Control on visionOS

Voice Control on visionOS works similarly to iOS. Elements must appear in "Show numbers" and have matching "Show names" labels. `accessibilityInputLabels` applies.

### VoiceOver on visionOS Navigation

- **Look** at an element → VoiceOver reads it
- **Pinch** (index finger + thumb) → Activates the focused element
- **Double pinch** → Navigate back
- **Swipe gesture** → Move to next/previous element (like iOS)

All standard accessibility modifiers apply. Ensure 3D content via `AccessibilityComponent` is complete.

### Spatial Audio and Accessibility

```swift
// Use AVAudioSession for spatial audio apps
// .spokenAudio mode is supported on visionOS
try? AVAudioSession.sharedInstance().setCategory(
    .playback,
    mode: .spokenAudio
)
```

---

## Cross-Platform Conditional Code

```swift
// Platform-conditional accessibility code
var body: some View {
    MyView()
        .accessibilityLabel("Chart")
#if os(macOS)
        // macOS: additional keyboard shortcut hint
        .accessibilityHint("Press Space to toggle data view")
#elseif os(tvOS)
        // tvOS: focus feedback note
        .accessibilityHint("Press Select to expand")
#else
        // iOS/iPadOS/visionOS: swipe hint
        .accessibilityHint("Double-tap to expand")
#endif
}
```

### Shared Accessibility Logic

```swift
// Protocol abstracts platform differences
protocol AccessibilityProvider {
    var accessibilityName: String { get }
    var accessibilityDescription: String? { get }
}

// Shared extension that works on all platforms
extension View {
    func applyAccessibility(from provider: AccessibilityProvider) -> some View {
        self
            .accessibilityLabel(provider.accessibilityName)
            .accessibilityHint(provider.accessibilityDescription ?? "")
    }
}
```

---

## Common Cross-Platform Mistakes

| Mistake | Platform | Fix |
|---|---|---|
| Using `UIAccessibility` in a macOS/AppKit target | macOS | Use `NSAccessibility` protocol instead |
| No focus animation on tvOS custom view | tvOS | Implement `didUpdateFocus` with `coordinator.addCoordinatedAnimations` |
| No `canBecomeFocused` override on tvOS custom view | tvOS | Override `canBecomeFocused` to return `true` |
| Assuming iOS swipe gestures work on watchOS | watchOS | watchOS uses tap/double-tap/crown, not swipe for VoiceOver |
| Missing `AccessibilityComponent` on RealityKit entities | visionOS | Add `AccessibilityComponent` with label, traits, and actions |
| Focus trapping not working in Mac Catalyst modal | macOS (Catalyst) | Set `accessibilityViewIsModal = true` — same as UIKit |
| WKAccessibilityIsReduceMotionEnabled not checked | watchOS | Use WatchKit function, not `UIAccessibility.isReduceMotionEnabled` |
| Hover effect without accessibility alternative | visionOS | Add `accessibilityLabel` + `accessibilityAddTraits(.isButton)` |
