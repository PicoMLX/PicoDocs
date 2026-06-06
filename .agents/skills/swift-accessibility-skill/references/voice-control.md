# Voice Control

Voice Control lets users navigate and interact with apps using only spoken commands. It is distinct from VoiceOver — it targets people with **motor disabilities** who can see the screen but cannot use their hands reliably.

## Contents
- [How Voice Control Works](#how-voice-control-works)
- [Input Labels - The Core API](#input-labels---the-core-api)
- ["Show Numbers" and "Show Names" Overlays](#show-numbers-and-show-names-overlays)
- [Custom Actions](#custom-actions)
- [Text Input and Editing](#text-input-and-editing)
- [Scrolling and Gestures](#scrolling-and-gestures)
- [SiriKit and App Intents](#sirikit-and-app-intents)
- [Testing Checklist](#testing-checklist)
- [Common Failures](#common-failures)

---

## How Voice Control Works

When a user says "Show numbers", every interactive element receives a numbered overlay. "Tap 5" activates element 5. "Show names" shows text labels. "Tap Send" activates the button labeled "Send".

**The critical rule:** The label Voice Control uses to identify an element must exactly match what the user sees on screen. A button that reads "Send" in the UI but has an `accessibilityLabel` of "Submit" will silently fail when the user says "Tap Send".

Voice Control uses this resolution order:
1. Visible text of the element
2. `accessibilityInputLabels` (first entry)
3. `accessibilityLabel`

If the visible text and `accessibilityLabel` don't match, Voice Control cannot reconcile them without `accessibilityInputLabels`.

---

## Input Labels - The Core API

### SwiftUI: `.accessibilityInputLabels(_:)`

Provides alternate names that Voice Control (and Siri) can use to activate an element. The **first entry** is also used as the default `accessibilityLabel` if no separate label is set.

```swift
// Icon-only button — no visible text, VoiceOver needs a label, Voice Control needs a name
Button { composeMessage() } label: {
    Image(systemName: "square.and.pencil")
}
.accessibilityLabel("Compose")           // VoiceOver label
.accessibilityInputLabels(["Compose", "New Message", "Write"])  // Voice Control names

// Abbreviated visible text — user might say the full phrase
Button("DL Report") { downloadReport() }
    .accessibilityInputLabels(["Download Report", "DL Report", "Export Report"])

// When visible text is unambiguous — no input labels needed
Button("Send") { send() }  // "Tap Send" just works
```

**Order matters:** List names from most to least specific. Voice Control uses the first match.

### UIKit: `accessibilityUserInputLabels`

```swift
button.accessibilityLabel = "Compose"
button.accessibilityUserInputLabels = ["Compose", "New Message", "Write"]
```

### When to Add Input Labels

| Situation | Action |
|---|---|
| Icon-only button | Always add input labels matching the action |
| Abbreviated visible text ("Msg", "DL", "Fav") | Add full-word alternatives |
| Visible text matches accessibilityLabel | Not needed |
| Visible text differs from accessibilityLabel | Required — or rewrite accessibilityLabel to match |
| Multiple buttons with same visible text | Add unique distinguishing labels |

---

## "Show Numbers" and "Show Names" Overlays

When Voice Control shows overlays, every **interactive** element must appear.

### Why Elements Go Missing

An element is invisible to Voice Control if:
- `isAccessibilityElement = false` (UIKit) or `.accessibilityHidden(true)` (SwiftUI)
- The element is a custom view with no accessibility info
- The element has no label and is not recognized as interactive
- The element uses a custom tap handler (`.onTapGesture`) without a proper accessible wrapper

### Make Custom Tappable Views Discoverable

```swift
// ❌ onTapGesture doesn't register as an interactive element for Voice Control
Image(systemName: "heart")
    .onTapGesture { toggleFavorite() }

// ✅ Button is always discovered by Voice Control
Button { toggleFavorite() } label: {
    Image(systemName: "heart")
}
.accessibilityLabel("Favorite")

// ✅ UIKit equivalent — ensure isAccessibilityElement = true and set a trait
let heartView = HeartView()
heartView.isAccessibilityElement = true
heartView.accessibilityTraits = .button
heartView.accessibilityLabel = "Favorite"
```

### Multiple Identical Labels

If two elements have the same name, Voice Control shows disambiguation ("Which 'Delete'?") requiring the user to tap the number. Prefer unique labels.

```swift
// ❌ Three "Delete" buttons — forces disambiguation
ForEach(items) { item in
    Button("Delete") { delete(item) }
}

// ✅ Unique labels
ForEach(items) { item in
    Button("Delete") { delete(item) }
        .accessibilityLabel("Delete \(item.name)")
}
```

---

## Custom Actions

When UI is only accessible via swipe (e.g., swipe-to-delete in a list), Voice Control needs a voice-accessible alternative.

### SwiftUI

```swift
// "Show actions for 3" reveals these as ">>" in Voice Control
MessageRow(message: message)
    .accessibilityAction(named: "Reply") { reply(message) }
    .accessibilityAction(named: "Archive") { archive(message) }
    .accessibilityAction(named: "Delete") { delete(message) }
```

Custom actions show a ">>" indicator next to the element number in "Show numbers" mode.

### UIKit

```swift
cell.accessibilityCustomActions = [
    UIAccessibilityCustomAction(name: "Reply") { [weak self] _ in
        self?.reply(message)
        return true
    },
    UIAccessibilityCustomAction(name: "Archive") { [weak self] _ in
        self?.archive(message)
        return true
    }
]
```

### Revealing Hidden UI

If content is only visible on hover/swipe (e.g., a delete button revealed by swiping a row), Voice Control users cannot discover or activate it without an explicit action.

```swift
// Hidden action on list row
struct ArticleRow: View {
    var article: Article
    @State private var showDeleteConfirm = false

    var body: some View {
        Text(article.title)
            .swipeActions {
                Button(role: .destructive) { delete(article) } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            // Voice Control alternative for swipe-to-delete
            .accessibilityAction(named: "Delete article") { delete(article) }
    }
}
```

---

## Text Input and Editing

All text fields must work with Voice Control's text commands.

### Commands Voice Control Uses

| Command | Action |
|---|---|
| "Type Hello" | Inserts "Hello" at cursor |
| "Select Hello" | Selects text "Hello" |
| "Select all" | Selects all text |
| "Delete that" | Deletes selected text |
| "Capitalize that" | Capitalizes selected text |
| "Bold that" | Bolds selected text (rich text) |

### Requirements

```swift
// ✅ Native TextField — works automatically
TextField("Email", text: $email)

// ✅ Native UITextField — works automatically
let field = UITextField()
field.placeholder = "Email"

// ⚠️ Custom text input — must test thoroughly
// Voice Control text selection and deletion may not work without native UITextInput conformance
```

**Always test every text field with:**
1. "Type [text]" — inserts text
2. "Select [visible word]" — selects specific text
3. "Delete that" — removes selected text

### Time-Limited Interactions

If your UI auto-hides or times out (e.g., a media player control bar that hides after 3 seconds), Voice Control users need time to issue commands.

There is no public runtime API to detect whether Voice Control is currently active.

- Avoid auto-hide for primary actions when possible.
- If controls must disappear, provide an explicit way to keep them visible long enough for spoken commands.
- Treat this as a manual verification requirement in Voice Control testing.

---

## Scrolling and Gestures

### Voice Commands for Navigation

| Command | Effect |
|---|---|
| "Scroll up/down/left/right" | Scrolls the current scroll view |
| "Scroll to top/bottom" | Scrolls to edge |
| "Pan left/right/up/down" | Pans a map or canvas |
| "Zoom in/out" | Zoom gesture |
| "Swipe left/right" | Swipe gesture |
| "Tap and hold [element]" | Long press |

### Multi-Touch Gestures

Some gestures have built-in Voice Control equivalents. Custom multi-touch gestures do **not** automatically work with Voice Control and require custom actions.

```swift
// Two-finger pinch — not automatically accessible
// Add a voice-accessible alternative:
PinchableView()
    .accessibilityAction(named: "Zoom in") { scale *= 1.5 }
    .accessibilityAction(named: "Zoom out") { scale /= 1.5 }
    .accessibilityAction(named: "Reset zoom") { scale = 1.0 }
```

---

## SiriKit and App Intents

Implementing App Intents enables Voice Control users to trigger app functionality with natural language — even deeper than the "Show numbers" approach.

```swift
struct SendMessageIntent: AppIntent {
    static var title: LocalizedStringResource = "Send Message"

    @Parameter(title: "Recipient")
    var recipient: String

    func perform() async throws -> some IntentResult {
        await sendMessage(to: recipient)
        return .result()
    }
}
```

---

## Testing Checklist

Test on device (not Simulator). Enable Voice Control in Settings → Accessibility → Voice Control.

### "Show numbers" Test
- [ ] Every button, link, and interactive element has a number
- [ ] No interactive elements are missing from the overlay
- [ ] "Tap [number]" activates each element correctly

### "Show names" Test
- [ ] Every element has a visible text label in the overlay
- [ ] Labels match the visible text in the UI
- [ ] No elements show generic labels ("button", "image")

### Voice Activation Test
- [ ] "Tap [visible text]" works for every labeled button
- [ ] "Tap [input label]" works for elements with alternate names
- [ ] Custom actions appear as ">>" and are activatable

### Text Input Test
- [ ] "Type [text]" works in every text field
- [ ] "Select [word]" selects text correctly
- [ ] "Delete that" deletes selected text

### Gesture Test
- [ ] Swipe-only UI has voice-accessible custom actions
- [ ] Custom multi-touch gestures have voice alternatives

---

## Common Failures

| Failure | Why | Fix |
|---|---|---|
| Element missing from "Show numbers" | Not recognized as interactive | Use `Button`, add `.accessibilityTraits(.button)` |
| "Tap Send" fails but button exists | `accessibilityLabel` is "Submit", not "Send" | Match label to visible text or add `.accessibilityInputLabels(["Send"])` |
| Dictation fails in custom text field | No `UITextInput` conformance | Use native `UITextField`/`UITextView` or implement `UITextInput` |
| Swipe-to-delete invisible to Voice Control | No voice alternative for swipe action | Add `.accessibilityAction(named: "Delete")` |
| Auto-hiding UI disappears before command completes | Short timeout | Extend timeout when accessibility features are active |
| Disambiguation required for identical labels | Two elements with same name | Add unique context: "Delete Photo", "Delete Video" |
| Custom tap handler not discovered | `.onTapGesture` has no accessibility role | Use `Button` instead |
