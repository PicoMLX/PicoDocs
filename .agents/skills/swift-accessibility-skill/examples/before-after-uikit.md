# Before/After: UIKit Accessibility

Concrete UIKit code transformations with priority tier annotations.

Priority tiers:
- **Blocks Assistive Tech** — Element is completely unreachable or unusable
- **Degrades Experience** — Reachable with significant friction
- **Incomplete Support** — Gaps that prevent Nutrition Label claims

## Contents

### Blocks Assistive Tech
- Custom view not in accessibility tree
- Container exposes element AND children
- Modal doesn't trap VoiceOver focus

### Degrades Experience
- Swipe-to-reveal actions not accessible
- Custom adjustable view missing increment/decrement
- Custom frame not in screen coordinates

### Incomplete Support
- No announcement after async content loads
- Cached accessibilityElements not invalidated

---

## [Blocks Assistive Tech] Custom view not in accessibility tree

**Problem:** A custom UIView subclass for a tappable card is not exposed to VoiceOver or Voice Control because `isAccessibilityElement` is `false` by default for UIView.

```swift
// ❌ Before
class ProductCardView: UIView {
    // No accessibility properties set
    // onTap gesture via UITapGestureRecognizer
}
```

```swift
// ✅ After
class ProductCardView: UIView {
    var product: Product? {
        didSet { updateAccessibility() }
    }

    override var isAccessibilityElement: Bool {
        get { true }
        set { }
    }

    override var accessibilityTraits: UIAccessibilityTraits {
        get { .button }
        set { }
    }

    override var accessibilityLabel: String? {
        get { product?.name }  // [VERIFY] confirm this label matches intent
        set { }
    }

    override var accessibilityHint: String? {
        get { "Opens product details" }
        set { }
    }

    private func updateAccessibility() {
        UIAccessibility.post(notification: .layoutChanged, argument: self)
    }
}
```

**Changes:**
| Change | Why |
|---|---|
| Set `isAccessibilityElement = true` | Opts the view into the accessibility tree |
| Set `accessibilityTraits = .button` | VoiceOver announces "button"; Voice Control shows element |
| Added `accessibilityLabel` | VoiceOver reads the product name |
| Added `accessibilityHint` | VoiceOver reads the result of activation |
| Post `.layoutChanged` on data change | VoiceOver updates its cached info |

---

## [Blocks Assistive Tech] Container exposes element AND children

**Problem:** The container has `isAccessibilityElement = true` AND sets `accessibilityElements`. VoiceOver reads the container AND its children — doubling content.

```swift
// ❌ Before
class RatingView: UIView {
    let starsLabel = UILabel()
    let countLabel = UILabel()

    override var isAccessibilityElement: Bool {
        get { true }  // ❌ CONFLICT with accessibilityElements below
        set { }
    }

    override var accessibilityElements: [Any]? {
        get { [starsLabel, countLabel] }
        set { }
    }
}
```

```swift
// ✅ After
class RatingView: UIView {
    let starsLabel = UILabel()
    let countLabel = UILabel()

    // Container is NOT an element — it exposes children
    override var isAccessibilityElement: Bool {
        get { false }
        set { }
    }

    override var accessibilityElements: [Any]? {
        get { [starsLabel, countLabel] }
        set { }
    }
}

// Configure labels
starsLabel.accessibilityLabel = "4.5 stars"
starsLabel.accessibilityTraits = .staticText
countLabel.accessibilityLabel = "2,304 ratings"
countLabel.accessibilityTraits = .staticText
```

**Changes:**
| Change | Why |
|---|---|
| `isAccessibilityElement = false` on container | Container exposes children via `accessibilityElements` — it must not also be an element |
| Configure child labels | Each child needs its own label |

---

## [Blocks Assistive Tech] Modal doesn't trap VoiceOver focus

**Problem:** When a custom modal is presented, VoiceOver can still navigate to elements behind it by swiping.

```swift
// ❌ Before
class AlertModalView: UIView {
    // Custom alert presented by addSubview
    // No focus trapping
}
```

```swift
// ✅ After
class AlertModalView: UIView {
    // Trap focus within this modal
    override var accessibilityViewIsModal: Bool {
        get { true }  // VoiceOver ignores everything behind this view
        set { }
    }
}

// Presenting:
func showAlert() {
    let modal = AlertModalView()
    view.addSubview(modal)

    // Focus moves into the modal
    UIAccessibility.post(notification: .screenChanged, argument: modal)
}

// In the modal's view controller:
override func accessibilityPerformEscape() -> Bool {
    dismissAlert()
    return true
}
```

**Changes:**
| Change | Why |
|---|---|
| `accessibilityViewIsModal = true` | VoiceOver ignores all views behind the modal |
| Post `.screenChanged` with modal | Focus moves into the modal on presentation |
| Implement `accessibilityPerformEscape()` | Two-finger Z gesture + Escape key dismiss the modal |

---

## [Degrades Experience] Swipe-to-reveal actions not accessible

**Problem:** Delete and archive are only accessible via swipe gesture. VoiceOver and Voice Control users cannot reach them.

```swift
// ❌ Before
class MessageCell: UITableViewCell {
    // Swipe actions configured in tableView(_:trailingSwipeActionsConfigurationForRowAt:)
    // No accessibility equivalent
}
```

```swift
// ✅ After
class MessageCell: UITableViewCell {
    var message: Message?

    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            guard let message = message else { return nil }
            return [
                UIAccessibilityCustomAction(
                    name: "Reply",
                    target: self,
                    selector: #selector(handleReply)
                ),
                UIAccessibilityCustomAction(
                    name: "Archive"
                ) { [weak self] _ in
                    self?.archiveMessage()
                    return true
                },
                UIAccessibilityCustomAction(
                    name: "Delete",
                    image: UIImage(systemName: "trash")
                ) { [weak self] _ in
                    self?.deleteMessage()
                    return true
                }
            ]
        }
        set { }
    }

    @objc private func handleReply() -> Bool {
        replyToMessage()
        return true  // true = action performed
    }
}
```

**Changes:**
| Change | Why |
|---|---|
| Added `accessibilityCustomActions` | VoiceOver Actions rotor; Voice Control ">>" indicator |
| Return `true` from action handlers | Signals action succeeded to VoiceOver |
| Added image to Delete action | Shows icon in VoiceOver action menu (optional) |
| Keep swipe actions in delegate | Sighted users keep the gesture |

---

## [Degrades Experience] Custom adjustable view missing increment/decrement

**Problem:** A star-rating view has `.adjustable` trait but doesn't implement the increment/decrement methods. VoiceOver plays the "adjustable" sound but nothing happens.

```swift
// ❌ Before
class StarRatingView: UIView {
    var rating: Int = 0

    override var accessibilityTraits: UIAccessibilityTraits {
        get { .adjustable }
        set { }
    }

    override var accessibilityValue: String? {
        get { "\(rating) stars" }
        set { }
    }
    // Missing: accessibilityIncrement and accessibilityDecrement
}
```

```swift
// ✅ After
class StarRatingView: UIView {
    var rating: Int = 0 {
        didSet {
            UIAccessibility.post(notification: .layoutChanged, argument: self)
        }
    }

    override var isAccessibilityElement: Bool { get { true } set {} }
    override var accessibilityLabel: String? { get { "Rating" } set {} }
    override var accessibilityTraits: UIAccessibilityTraits { get { .adjustable } set {} }
    override var accessibilityValue: String? {
        get { "\(rating) out of 5 stars" }
        set {}
    }
    override var accessibilityHint: String? {
        get { "Swipe up or down to change rating" }
        set {}
    }

    override func accessibilityIncrement() {
        rating = min(5, rating + 1)
    }

    override func accessibilityDecrement() {
        rating = max(0, rating - 1)
    }
}
```

**Changes:**
| Change | Why |
|---|---|
| Added `accessibilityIncrement()` | Required for `.adjustable` trait — swipe up increases |
| Added `accessibilityDecrement()` | Required for `.adjustable` trait — swipe down decreases |
| Post `.layoutChanged` on rating change | VoiceOver re-reads updated value |
| Added `accessibilityHint` | Tells user how to interact with adjustable element |
| Better `accessibilityValue` wording | "out of 5 stars" is more descriptive than just "3 stars" |

---

## [Degrades Experience] Custom frame not in screen coordinates

**Problem:** `accessibilityFrame` returns local view coordinates. VoiceOver draws focus ring in the wrong position.

```swift
// ❌ Before
class BadgeView: UIView {
    override var accessibilityFrame: CGRect {
        get { bounds }  // ❌ Local coordinates, not screen coordinates
        set { }
    }
}
```

```swift
// ✅ After
class BadgeView: UIView {
    override var accessibilityFrame: CGRect {
        get {
            // Convert to screen coordinates
            UIAccessibility.convertToScreenCoordinates(bounds, in: self)
        }
        set { }
    }
}
```

**Changes:**
| Change | Why |
|---|---|
| Use `UIAccessibility.convertToScreenCoordinates(bounds, in: self)` | `accessibilityFrame` must be in screen coordinates; local bounds are wrong |

---

## [Incomplete Support] No announcement after async content loads

**Problem:** When a network request completes and new content appears, VoiceOver users don't know the content changed. They must manually explore to discover it.

```swift
// ❌ Before
func loadMessages() {
    Task {
        messages = try await api.fetchMessages()
        tableView.reloadData()
        // VoiceOver doesn't know content changed
    }
}
```

```swift
// ✅ After
func loadMessages() {
    Task {
        messages = try await api.fetchMessages()
        tableView.reloadData()

        // Announce the update AND move focus to relevant content
        if messages.isEmpty {
            UIAccessibility.post(
                notification: .announcement,
                argument: "No messages"
            )
        } else {
            // Move focus to first new message
            let firstCell = tableView.cellForRow(at: IndexPath(row: 0, section: 0))
            UIAccessibility.post(notification: .layoutChanged, argument: firstCell)
        }
    }
}
```

**Changes:**
| Change | Why |
|---|---|
| Post `.layoutChanged` with first cell | VoiceOver focus moves to the new content |
| Post `.announcement` for empty state | Announces that no content was found |
| Chose `.layoutChanged` over `.screenChanged` | Partial update (new rows, not new screen) |

---

## [Incomplete Support] Cached accessibilityElements not invalidated

**Problem:** A custom chart view caches its accessibility elements but doesn't refresh them when data changes. VoiceOver reads stale data.

```swift
// ❌ Before
class ChartView: UIView {
    var data: [ChartPoint] = [] {
        didSet {
            setNeedsDisplay()
            // ❌ Cached elements not invalidated
        }
    }

    private var cachedElements: [UIAccessibilityElement]?

    override var accessibilityElements: [Any]? {
        get {
            if cachedElements == nil {
                cachedElements = buildElements()
            }
            return cachedElements
        }
        set { cachedElements = newValue as? [UIAccessibilityElement] }
    }
}
```

```swift
// ✅ After
class ChartView: UIView {
    var data: [ChartPoint] = [] {
        didSet {
            setNeedsDisplay()
            cachedElements = nil  // ✅ Invalidate cache
            UIAccessibility.post(notification: .layoutChanged, argument: nil)
        }
    }

    private var cachedElements: [UIAccessibilityElement]?

    override var isAccessibilityElement: Bool {
        get { false }  // Container exposes children
        set { }
    }

    override var accessibilityElements: [Any]? {
        get {
            if cachedElements == nil {
                cachedElements = data.enumerated().map { index, point in
                    let element = UIAccessibilityElement(accessibilityContainer: self)
                    element.accessibilityLabel = point.label
                    element.accessibilityValue = "\(point.value) units"
                    element.accessibilityTraits = .staticText
                    element.accessibilityFrame = UIAccessibility.convertToScreenCoordinates(
                        frameForPoint(at: index), in: self
                    )
                    return element
                }
            }
            return cachedElements
        }
        set { cachedElements = newValue as? [UIAccessibilityElement] }
    }
}
```

**Changes:**
| Change | Why |
|---|---|
| `cachedElements = nil` in `didSet` | Forces rebuild on next VoiceOver access |
| Post `.layoutChanged` after data change | Tells VoiceOver the layout changed; triggers refresh |
| Set `isAccessibilityElement = false` on container | Container exposes children — must not be an element itself |
| Convert frame to screen coordinates | `accessibilityFrame` requires screen coordinates |
