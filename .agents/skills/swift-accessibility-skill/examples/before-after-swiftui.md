# Before/After: SwiftUI Accessibility

Concrete code transformations with priority tier annotations. Each example shows the inaccessible version, the corrected version, and a summary of every change.

Priority tiers:
- **Blocks Assistive Tech** — Element is completely unreachable or unusable
- **Degrades Experience** — Reachable with significant friction
- **Incomplete Support** — Gaps that prevent Nutrition Label claims

## Contents

### Blocks Assistive Tech
- Icon-only button missing label
- Tappable view using `onTapGesture`
- Decorative image announced by VoiceOver

### Degrades Experience
- Label includes control type
- State embedded in label
- Touch target too small
- Long-press menu without VoiceOver equivalent

### Incomplete Support
- Text doesn't scale with Dynamic Type
- Animation plays with Reduce Motion enabled
- Color-only status indicator
- VoiceOver modal allows background access
- Custom slider missing adjustable support

---

## [Blocks Assistive Tech] Icon-only button missing label

**Problem:** VoiceOver announces "square.and.arrow.up" (the SF Symbol name). Voice Control cannot identify the button. Neither feature can use this control correctly.

```swift
// ❌ Before
Button(action: shareDocument) {
    Image(systemName: "square.and.arrow.up")
}
```

```swift
// ✅ After
Button(action: shareDocument) {
    Image(systemName: "square.and.arrow.up")
}
.accessibilityLabel("Share")                           // [VERIFY] confirm this matches intent
.accessibilityInputLabels(["Share", "Share Document"]) // Voice Control alternate names
```

**Changes:**
| Change | Why |
|---|---|
| Added `.accessibilityLabel("Share")` | VoiceOver reads the action, not the symbol name |
| Added `.accessibilityInputLabels(["Share", "Share Document"])` | Voice Control: "Tap Share" and "Tap Share Document" both work |
| Added `[VERIFY]` comment | Label inferred from symbol — developer must confirm it matches the action |

---

## [Blocks Assistive Tech] Tappable view using `onTapGesture`

**Problem:** VoiceOver has no label and treats this as non-interactive. Voice Control's "Show numbers" doesn't include it. Switch Control skips it.

```swift
// ❌ Before
HStack {
    Image(product.thumbnail)
    VStack(alignment: .leading) {
        Text(product.name)
        Text(product.price, format: .currency(code: "USD"))
    }
}
.onTapGesture { openProduct(product) }
```

```swift
// ✅ After
Button(action: { openProduct(product) }) {
    HStack {
        Image(product.thumbnail)
            .accessibilityHidden(true)  // decorative — name announced via label below
        VStack(alignment: .leading) {
            Text(product.name)
            Text(product.price, format: .currency(code: "USD"))
        }
    }
}
.accessibilityLabel("\(product.name), \(product.formattedPrice)")
.accessibilityHint("Opens product details")
```

**Changes:**
| Change | Why |
|---|---|
| Replaced `onTapGesture` with `Button` | `Button` is automatically interactive for VoiceOver, Voice Control, and keyboard |
| Added `.accessibilityLabel(...)` | Combined label prevents VoiceOver from reading child elements separately |
| Added `.accessibilityHidden(true)` on image | Thumbnail is redundant with label — hide from accessibility tree |
| Added `.accessibilityHint(...)` | Explains the result without being redundant with the label |

---

## [Blocks Assistive Tech] Decorative image announced by VoiceOver

**Problem:** VoiceOver reads "Image: background-wave" interrupting the reading flow.

```swift
// ❌ Before
Image("background-wave")
    .frame(height: 200)
```

```swift
// ✅ After
Image("background-wave")
    .frame(height: 200)
    .accessibilityHidden(true)
```

**Changes:**
| Change | Why |
|---|---|
| Added `.accessibilityHidden(true)` | Removes decorative image from accessibility tree entirely |

---

## [Degrades Experience] Label includes control type

**Problem:** VoiceOver announces "Delete button, button" — double-announces the type.

```swift
// ❌ Before
Button("Delete button") { delete(item) }
```

```swift
// ✅ After
Button("Delete") { delete(item) }
    .accessibilityLabel("Delete \(item.name)") // unique label per item
```

**Changes:**
| Change | Why |
|---|---|
| Removed "button" from label | VoiceOver adds "button" automatically from the `.isButton` trait |
| Added item name to label | Prevents disambiguation when multiple Delete buttons appear |

---

## [Degrades Experience] State embedded in label

**Problem:** When the favorite state changes, VoiceOver re-reads the full label. State should be a trait, not a label change.

```swift
// ❌ Before
Button(action: toggleFavorite) {
    Image(systemName: item.isFavorited ? "star.fill" : "star")
}
.accessibilityLabel(item.isFavorited ? "Favorited" : "Not favorited")
```

```swift
// ✅ After
Button(action: toggleFavorite) {
    Image(systemName: item.isFavorited ? "star.fill" : "star")
}
.accessibilityLabel("Favorite")
.accessibilityAddTraits(item.isFavorited ? .isSelected : [])
.accessibilityHint(item.isFavorited ? "Removes from favorites" : "Adds to favorites")
```

**Changes:**
| Change | Why |
|---|---|
| Label is always "Favorite" | Stable label — VoiceOver doesn't re-read on state change |
| Added `.accessibilityAddTraits(.isSelected)` when favorited | VoiceOver announces "selected" — correct for iOS 13–16 targets |
| Added `.accessibilityHint(...)` describing result | Tells user what activating will do based on current state |

> **iOS 17+ note:** Prefer `.accessibilityAddTraits(.isToggle)` over `.isSelected` for toggle controls. `.isToggle` identifies the *type* of control (binary on/off), while `.isSelected` conveys *current selection state* (e.g., selected tab). For favorite/bookmark buttons targeting iOS 17+, use `.isToggle` and express the current state via `accessibilityValue("On")` / `accessibilityValue("Off")`.

---

## [Degrades Experience] Touch target too small

**Problem:** The heart icon is 20×20pt. The tap area is too small for many users, especially those with motor impairments.

```swift
// ❌ Before
Image(systemName: "heart")
    .font(.system(size: 20))
    .onTapGesture { toggleFavorite() }
```

```swift
// ✅ After
Button(action: toggleFavorite) {
    Image(systemName: "heart")
        .font(.system(size: 20))
}
.frame(minWidth: 44, minHeight: 44)
.contentShape(Rectangle())
.accessibilityLabel("Favorite")
```

**Changes:**
| Change | Why |
|---|---|
| Changed `onTapGesture` to `Button` | Makes element accessible to VoiceOver and Voice Control |
| Added `.frame(minWidth: 44, minHeight: 44)` | Ensures minimum 44×44pt touch target |
| Added `.contentShape(Rectangle())` | Ensures the full frame is tappable, not just the icon |
| Added `.accessibilityLabel("Favorite")` | Icon-only button needs explicit label |

---

## [Degrades Experience] Long-press menu without VoiceOver equivalent

**Problem:** The context menu is only accessible via long press. VoiceOver users cannot discover or trigger these actions.

```swift
// ❌ Before
MessageRow(message: message)
    .contextMenu {
        Button("Reply") { reply(message) }
        Button("Forward") { forward(message) }
        Button("Delete", role: .destructive) { delete(message) }
    }
```

```swift
// ✅ After
MessageRow(message: message)
    .contextMenu {
        Button("Reply") { reply(message) }
        Button("Forward") { forward(message) }
        Button("Delete", role: .destructive) { delete(message) }
    }
    // VoiceOver: Actions rotor; Voice Control: ">>" indicator
    .accessibilityAction(named: "Reply") { reply(message) }
    .accessibilityAction(named: "Forward") { forward(message) }
    .accessibilityAction(named: "Delete") { delete(message) }
```

**Changes:**
| Change | Why |
|---|---|
| Added `.accessibilityAction(named:)` for each action | VoiceOver Actions rotor can access them; Voice Control shows ">>" |
| Context menu kept | Sighted users keep the expected gesture — not removed |

---

## [Incomplete Support] Text doesn't scale with Dynamic Type

**Problem:** Fixed font size means text stays small even when the user has selected a larger accessibility size.

```swift
// ❌ Before
Text(article.title)
    .font(.system(size: 17))
Text(article.body)
    .font(.system(size: 14))
```

```swift
// ✅ After
Text(article.title)
    .font(.headline)           // scales with Dynamic Type
Text(article.body)
    .font(.body)               // scales with Dynamic Type
```

**Changes:**
| Change | Why |
|---|---|
| `.system(size: 17)` → `.headline` | Semantic text style scales with user's preferred size |
| `.system(size: 14)` → `.body` | Semantic text style scales; reads as body content |

---

## [Incomplete Support] Animation plays with Reduce Motion enabled

**Problem:** A slide transition plays even when the user has enabled Reduce Motion to avoid vestibular issues.

```swift
// ❌ Before
if isVisible {
    DetailView()
        .transition(.slide)
}
```

```swift
// ✅ After
@Environment(\.accessibilityReduceMotion) var reduceMotion

// In body:
if isVisible {
    DetailView()
        .transition(reduceMotion ? .opacity : .slide)
}
```

**Changes:**
| Change | Why |
|---|---|
| Read `@Environment(\.accessibilityReduceMotion)` | Detect user preference |
| Switch `.slide` to `.opacity` when reduce motion is on | Fade preserves meaning without vestibular-triggering motion |

---

## [Incomplete Support] Color-only status indicator

**Problem:** Online status is shown only by color (green = online, red = offline). Fails grayscale test and Differentiate Without Color.

```swift
// ❌ Before
Circle()
    .fill(user.isOnline ? .green : .red)
    .frame(width: 12, height: 12)
```

```swift
// ✅ After
Group {
    if user.isOnline {
        Circle()
            .fill(.green)
            .frame(width: 12, height: 12)
    } else {
        Circle()
            .fill(.red)
            .overlay(
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white)
            )
            .frame(width: 12, height: 12)
    }
}
.accessibilityLabel(user.isOnline ? "Online" : "Offline")
```

**Changes:**
| Change | Why |
|---|---|
| Added xmark icon on offline circle | Shape distinguishes states in grayscale |
| Added `.accessibilityLabel(...)` | VoiceOver reads semantic state, not just color |
| Kept color differentiation | Doesn't break sighted users — shape is additive |

---

## [Incomplete Support] VoiceOver modal allows background access

**Problem:** When a modal is presented, VoiceOver can still swipe to reach elements behind it.

```swift
// ❌ Before
struct ConfirmationModal: View {
    @Binding var isPresented: Bool

    var body: some View {
        VStack {
            Text("Are you sure?")
            Button("Confirm") {
                // ...
                isPresented = false
            }
            Button("Cancel") { isPresented = false }
        }
        .padding()
        .background(Color(.systemBackground))
    }
}
```

```swift
// ✅ After
struct ConfirmationModal: View {
    @Binding var isPresented: Bool
    @AccessibilityFocusState private var isConfirmFocused: Bool

    var body: some View {
        VStack {
            Text("Are you sure?")
            Button("Confirm") {
                // ...
                isPresented = false
            }
                .accessibilityFocused($isConfirmFocused)
            Button("Cancel") { isPresented = false }
        }
        .padding()
        .background(Color(.systemBackground))
        .accessibilityElement(children: .contain)
        .onAppear { isConfirmFocused = true }
    }
}

// Presenting site — prefer .sheet() which traps focus automatically:
.sheet(isPresented: $showConfirm) {
    ConfirmationModal(isPresented: $showConfirm)
}
```

**Changes:**
| Change | Why |
|---|---|
| Use `.sheet()` for presentation | `.sheet()` traps VoiceOver focus automatically |
| Added `@AccessibilityFocusState` + `.onAppear` | Focus moves to Confirm button when modal appears |
| Added `.accessibilityElement(children: .contain)` | Ensures logical grouping within the modal |

---

## [Incomplete Support] Custom slider missing adjustable support

**Problem:** VoiceOver reaches the slider but cannot change its value (no swipe up/down support).

```swift
// ❌ Before
CustomSliderView(value: $brightness)
    .accessibilityLabel("Brightness")
```

```swift
// ✅ After
CustomSliderView(value: $brightness)
    .accessibilityLabel("Brightness")
    .accessibilityValue("\(Int(brightness * 100)) percent")
    .accessibilityAdjustableAction { direction in
        switch direction {
        case .increment: brightness = min(1, brightness + 0.05)
        case .decrement: brightness = max(0, brightness - 0.05)
        @unknown default: break
        }
    }
```

**Changes:**
| Change | Why |
|---|---|
| Added `.accessibilityValue(...)` | Announces current value when focused |
| Added `.accessibilityAdjustableAction(...)` | Enables VoiceOver swipe up/down to change value |
