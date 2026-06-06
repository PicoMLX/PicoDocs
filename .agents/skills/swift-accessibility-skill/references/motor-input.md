# Motor and Alternative Input

Covers accessibility for users who interact with devices through means other than direct touch: Switch Control, Full Keyboard Access, AssistiveTouch, and Guided Access.

## Contents
- [Touch Target Sizing](#touch-target-sizing)
- [Switch Control](#switch-control)
- [Full Keyboard Access (iOS / iPadOS)](#full-keyboard-access-ios--ipados)
- [tvOS Focus Engine](#tvos-focus-engine)
- [AssistiveTouch](#assistivetouch)
- [Guided Access](#guided-access)
- [Common Patterns Checklist](#common-patterns-checklist)

---

## Touch Target Sizing

All interactive elements must have a touch target of at least **44×44 points**. Small targets are a Nutrition Label failure and a common accessibility audit finding.

### SwiftUI

```swift
// ✅ contentShape extends the hit area without changing visual size
Image(systemName: "heart")
    .font(.system(size: 20))
    .contentShape(Rectangle())
    .frame(minWidth: 44, minHeight: 44)

// ✅ Alternatively, use padding to expand the tap area
Button { toggleFavorite() } label: {
    Image(systemName: "heart").font(.system(size: 20))
}
.padding(12)   // expands tap area to ~44pt

// ❌ Visual and tap area are both 20×20
Image(systemName: "heart")
    .font(.system(size: 20))
    .onTapGesture { toggleFavorite() }
```

### UIKit

```swift
// Override pointInside to extend the hit area
class LargeHitButton: UIButton {
    var hitAreaInsets = UIEdgeInsets(top: -12, left: -12, bottom: -12, right: -12)

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let hitArea = bounds.inset(by: hitAreaInsets)
        return hitArea.contains(point)
    }
}

// Or override accessibilityFrame to report a larger area
override var accessibilityFrame: CGRect {
    let frame = convert(bounds, to: nil)
    let minSize: CGFloat = 44
    let dX = max(0, (minSize - frame.width) / 2)
    let dY = max(0, (minSize - frame.height) / 2)
    return frame.insetBy(dx: -dX, dy: -dY)
}
```

---

## Switch Control

Switch Control allows users to navigate with one or more adaptive switches (physical buttons, sip-and-puff, sound input). Items highlight sequentially; the user activates their switch to select the highlighted element.

### How Navigation Works

1. **Item scanning** — elements highlight one by one
2. **Group scanning** — groups highlight first, then individual items within
3. **Point scanning** — a crosshair moves across the screen

Developers primarily need to ensure:
- All interactive elements are reachable
- Operations don't time out
- Complex gestures have switch-accessible alternatives

### Custom Actions for Gestures

Any swipe, long-press, or multi-touch gesture must have a custom action alternative.

```swift
// SwiftUI
FeedCard(post: post)
    .accessibilityAction(named: "Like") { like(post) }
    .accessibilityAction(named: "Comment") { showComment(post) }
    .accessibilityAction(named: "Share") { share(post) }
    .accessibilityAction(named: "Save") { save(post) }

// UIKit
cell.accessibilityCustomActions = [
    UIAccessibilityCustomAction(name: "Like") { _ in self.like(post); return true },
    UIAccessibilityCustomAction(name: "Share") { _ in self.share(post); return true }
]
```

### Grouping for Efficient Scanning

Use `shouldGroupAccessibilityChildren = true` (UIKit) or `.accessibilityElement(children: .contain)` (SwiftUI) to create a group. Users can skip the whole group with one switch tap if it's not relevant.

```swift
// SwiftUI — group sidebar as a unit
SidebarView()
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Sidebar")

// UIKit
sidebarView.shouldGroupAccessibilityChildren = true
sidebarView.accessibilityLabel = "Sidebar"
```

### Detecting Switch Control

Use only for UI optimization, never to branch core logic.

```swift
if UIAccessibility.isSwitchControlRunning {
    // Simplify animations, increase tap target feedback
}
```

### Time-Limited Interactions

Never require interactions to complete within a fixed time window. Switch Control users operate significantly slower than direct touch.

```swift
// ❌ Auto-advances after 3 seconds — inaccessible
DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
    self.advanceToNextStep()
}

// ✅ Require explicit user action
Button("Next Step") { advanceToNextStep() }
```

---

## Full Keyboard Access (iOS / iPadOS)

Full Keyboard Access (Settings → Accessibility → Keyboards → Full Keyboard Access) allows complete navigation using a hardware keyboard. Essential for iPad users and Mac Catalyst apps.

### How It Works

- **Tab** — move focus forward
- **Shift+Tab** — move focus backward
- **Space / Return** — activate focused element
- **Escape** — dismiss modal / cancel
- **Arrow keys** — navigate within components (pickers, sliders)

### All Elements Must Be Keyboard-Focusable

Native SwiftUI and UIKit controls are keyboard-accessible by default. Custom interactive views require opt-in.

```swift
// SwiftUI — custom tappable view needs to be a Button or use .accessibilityAddTraits(.isButton)
// Non-Button views that use onTapGesture may not receive keyboard focus

// ✅ Button receives keyboard focus automatically
Button("Open Settings") { openSettings() }

// ⚠️ Custom view — test keyboard navigation explicitly
CustomTileView()
    .accessibilityAddTraits(.isButton)
    .onTapGesture { handleTap() }
    // May not receive keyboard focus — prefer using Button
```

### Detecting Full Keyboard Access

```swift
if UIAccessibility.isFullKeyboardAccessEnabled {
    // Show keyboard shortcut hints in UI
}
```

### Modal Dismissal via Escape

Every modal, sheet, popover, and alert must be dismissible with the Escape key.

```swift
// SwiftUI — sheets dismiss via Escape automatically when using .sheet()
.sheet(isPresented: $showSettings) {
    SettingsView()
}

// UIKit custom modal — implement accessibilityPerformEscape
class CustomModalViewController: UIViewController {
    override func accessibilityPerformEscape() -> Bool {
        dismiss(animated: true)
        return true
    }
}
```

### Focus Guide — Bridge Focus Gaps

When keyboard focus can't naturally reach an area of the screen (e.g., a floating button overlaps other content), use `UIFocusGuide` to redirect focus.

```swift
// UIKit
let focusGuide = UIFocusGuide()
view.addLayoutGuide(focusGuide)
focusGuide.preferredFocusEnvironments = [floatingButton]

// Constrain the guide to fill the gap area
NSLayoutConstraint.activate([
    focusGuide.topAnchor.constraint(equalTo: gapArea.topAnchor),
    focusGuide.leadingAnchor.constraint(equalTo: gapArea.leadingAnchor),
    focusGuide.trailingAnchor.constraint(equalTo: gapArea.trailingAnchor),
    focusGuide.bottomAnchor.constraint(equalTo: gapArea.bottomAnchor)
])
```

### `accessibilityRespondsToUserInteraction(_:)` (SwiftUI, iOS 17+)

Marks a view as interactive for keyboard focus purposes.

```swift
CustomInteractiveView()
    .accessibilityRespondsToUserInteraction(true)
```

---

## tvOS Focus Engine

On tvOS, the Siri Remote navigates entirely through the **Focus Engine**. There is no pointer; UI elements highlight as they receive focus.

### Focus Basics

- Every focusable view must implement `canBecomeFocused` or use a native focusable control
- Focus moves between elements using the Siri Remote directional pad
- The Menu button = back / escape
- Long-press on Select = context menu

### Making Custom Views Focusable

```swift
// UIKit (tvOS)
class FocusableCardView: UIView {
    override var canBecomeFocused: Bool { true }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        if context.nextFocusedView === self {
            coordinator.addCoordinatedAnimations({
                self.transform = CGAffineTransform(scaleX: 1.1, y: 1.1)
                self.layer.shadowOpacity = 0.5
            })
        } else if context.previouslyFocusedView === self {
            coordinator.addCoordinatedAnimations({
                self.transform = .identity
                self.layer.shadowOpacity = 0
            })
        }
    }
}
```

### Setting Default Focus

```swift
// UIKit — preferredFocusEnvironments is evaluated top-to-bottom
override var preferredFocusEnvironments: [UIFocusEnvironment] {
    return [primaryButton]
}

// Deprecated — use preferredFocusEnvironments (shown above) instead
override weak var preferredFocusedView: UIView? { primaryButton }
```

### UIFocusGuide — Redirect Focus

```swift
let guide = UIFocusGuide()
view.addLayoutGuide(guide)
guide.preferredFocusEnvironments = [targetButton]

// Guide occupies the empty space between two buttons
NSLayoutConstraint.activate([
    guide.leadingAnchor.constraint(equalTo: leftButton.trailingAnchor),
    guide.trailingAnchor.constraint(equalTo: rightButton.leadingAnchor),
    guide.topAnchor.constraint(equalTo: leftButton.topAnchor),
    guide.bottomAnchor.constraint(equalTo: leftButton.bottomAnchor)
])
```

### Debugging Focus

In the iOS Simulator with tvOS target: Debug → View → Show Focus for Focus Engine Debug.

---

## AssistiveTouch

AssistiveTouch displays a floating virtual button that provides access to gestures, hardware buttons, and custom sequences. Most AssistiveTouch support is automatic if VoiceOver and basic accessibility are implemented.

### Detecting AssistiveTouch

```swift
if UIAccessibility.isAssistiveTouchRunning {
    // Optional: simplify complex gestures, show alternative controls
}

// Observe changes
NotificationCenter.default.addObserver(
    forName: UIAccessibility.assistiveTouchStatusDidChangeNotification,
    object: nil, queue: .main
) { _ in
    // Update UI
}
```

### AssistiveTouch + Custom Gestures

Custom multi-touch gestures are inaccessible to AssistiveTouch. Always provide single-tap or button alternatives.

---

## Guided Access

Guided Access locks the device to a single app with optional feature restrictions. Used in kiosks, educational apps, and focus-mode scenarios.

### Checking Guided Access State

```swift
if UIAccessibility.isGuidedAccessEnabled {
    // Lock navigation, hide sensitive controls
}

// Observe changes
NotificationCenter.default.addObserver(
    forName: UIAccessibility.guidedAccessStatusDidChangeNotification,
    object: nil, queue: .main
) { _ in
    updateForGuidedAccess()
}
```

### GuidedAccessRestrictions — Per-Feature Restrictions

Implement `UIGuidedAccessRestrictionDelegate` to offer fine-grained restrictions that educators or caregivers can toggle.

```swift
class AppDelegate: UIResponder, UIApplicationDelegate, UIGuidedAccessRestrictionDelegate {

    var guidedAccessRestrictionIdentifiers: [String] {
        ["com.myapp.restriction.settings",
         "com.myapp.restriction.purchases"]
    }

    func textForGuidedAccessRestriction(withIdentifier restrictionIdentifier: String) -> String? {
        switch restrictionIdentifier {
        case "com.myapp.restriction.settings": return "Settings"
        case "com.myapp.restriction.purchases": return "In-App Purchases"
        default: return nil
        }
    }

    func guidedAccessRestriction(withIdentifier restrictionIdentifier: String,
                                  didChange newRestrictionState: UIAccessibility.GuidedAccessRestrictionState) {
        switch restrictionIdentifier {
        case "com.myapp.restriction.settings":
            settingsButton.isHidden = (newRestrictionState == .deny)
        default: break
        }
    }
}
```

### Programmatic Guided Access Control

```swift
// Enter/exit Single App Mode programmatically (for kiosk apps)
// Note: requires a supervised device or MDM enrollment
UIAccessibility.requestGuidedAccessSession(enabled: true) { success in
    if success { print("Guided Access session started") }
}
```

---

## Common Patterns Checklist

- [ ] All interactive elements ≥ 44×44pt touch target
- [ ] Swipe-only gestures have `accessibilityCustomAction` alternatives
- [ ] No interactions time out without user control
- [ ] Every modal dismissible with Escape key
- [ ] Custom views use `Button` or have `.accessibilityTraits(.button)` for keyboard reachability
- [ ] tvOS: custom views override `canBecomeFocused` and animate focus changes
- [ ] Guided Access restrictions defined if app has lockable features
