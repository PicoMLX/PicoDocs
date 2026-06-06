# VoiceOver — SwiftUI

## Contents
- [Labels, Hints, Values](#labels-hints-values)
- [Traits](#traits)
- [Actions](#actions)
- [Grouping and Structure](#grouping-and-structure)
- [Focus Management](#focus-management)
- [Custom Rotors](#custom-rotors)
- [Announcements and Live Regions](#announcements-and-live-regions)
- [Speech Modifiers](#speech-modifiers)
- [Advanced Modifiers](#advanced-modifiers)
- [Common Mistakes](#common-mistakes)

---

## Labels, Hints, Values

### `.accessibilityLabel(_:)`
The text VoiceOver announces for any non-text element. Required for icon-only buttons and images.

```swift
// ✅ Good — concise, context-independent
Button(action: share) {
    Image(systemName: "square.and.arrow.up")
}
.accessibilityLabel("Share")

// ❌ Bad — includes control type (VoiceOver adds "button" automatically)
.accessibilityLabel("Share button")

// ❌ Bad — context-dependent, unintelligible alone
.accessibilityLabel("More")

// ❌ Bad — action description belongs in hint
.accessibilityLabel("Tap to share this post")
```

**`[VERIFY]` rule:** When inferring a label from an SF Symbol name or action method, add a comment:
```swift
Button { deleteItem() } label: { Image(systemName: "trash") }
    .accessibilityLabel("Delete item") // [VERIFY] confirm label matches intent
```

### `.accessibilityHint(_:)`
Briefly describes the **result** of activating the element (not the action itself). VoiceOver reads it after a short pause.

```swift
Button("Save") { save() }
    .accessibilityHint("Saves your changes and closes the editor")

// ❌ Bad — describes the action, not the result
.accessibilityHint("Tap to save")

// ❌ Bad — redundant with the label
Button("Delete") { delete() }
    .accessibilityHint("Deletes") // pointless
```

Omit hints when the result is obvious from the label alone.

### `.accessibilityValue(_:)`
The current value of controls that change over time: sliders, steppers, progress indicators, toggles with non-standard states.

```swift
Slider(value: $volume, in: 0...1)
    .accessibilityLabel("Volume")
    .accessibilityValue("\(Int(volume * 100)) percent")

// Custom progress indicator
Circle()
    .trim(from: 0, to: progress)
    .accessibilityLabel("Upload progress")
    .accessibilityValue("\(Int(progress * 100)) percent complete")
```

Do not use `.accessibilityValue` to repeat the label or append static text.

### `.accessibilityIdentifier(_:)`
A stable string for use in UI tests. **Not announced by VoiceOver.** Use for `XCUITest` element queries.

```swift
TextField("Search", text: $query)
    .accessibilityIdentifier("searchField")
```

### `.accessibilityLabeledPair(role:id:in:)`
Pairs a label with its corresponding control (e.g., a `Text` label next to a `TextField`).

```swift
@Namespace var formNamespace

Text("Full name")
    .accessibilityLabeledPair(role: .label, id: "fullName", in: formNamespace)

TextField("", text: $name)
    .accessibilityLabeledPair(role: .content, id: "fullName", in: formNamespace)
```

---

## Traits

Traits describe the **semantic role** and **state** of an element. VoiceOver announces them automatically (e.g., "button", "selected", "header").

### Adding and Removing Traits

```swift
.accessibilityAddTraits(.isButton)
.accessibilityAddTraits([.isButton, .isSelected])
.accessibilityRemoveTraits(.isButton)
```

### Full Trait Reference

| Trait | When to Use |
|---|---|
| `.isButton` | Any tappable element that isn't a native `Button` |
| `.isLink` | Opens a URL or navigates outside the app |
| `.isHeader` | Section headers (h1–h6 equivalent) |
| `.isSelected` | Currently selected item in a list or tab |
| `.isToggle` | Boolean on/off control |
| `.isImage` | Decorative or informational image |
| `.isSearchField` | Search input field |
| `.isStaticText` | Non-interactive text |
| `.playsSound` | Activating this element plays a sound |
| `.isKeyboardKey` | Custom keyboard key |
| `.updatesFrequently` | Announces updates as a live region |
| `.causesPageTurn` | Triggers a page turn (e.g., in a book reader) |
| `.allowsDirectInteraction` | Passes raw touch events to the view |
| `.isSummaryElement` | Read when the app launches (system summary) |

### State via Traits — Not Labels

```swift
// ✅ Good — state as trait
Image(systemName: item.isStarred ? "star.fill" : "star")
    .accessibilityLabel("Favorite")
    .accessibilityAddTraits(item.isStarred ? .isSelected : [])

// ❌ Bad — state embedded in label (changes require re-announcing the whole label)
.accessibilityLabel(item.isStarred ? "Favorited" : "Not favorited")
```

---

## Actions

### `.accessibilityAction(_:_:)` — Named Custom Action

Adds entries to VoiceOver's Actions rotor. Used for operations available via long-press, swipe, or context menu.

```swift
MessageRow(message: message)
    .accessibilityAction(named: "Reply") { replyTo(message) }
    .accessibilityAction(named: "Forward") { forward(message) }
    .accessibilityAction(named: "Delete") { delete(message) }
```

### `.accessibilityActions(_:)` — Multiple Actions via ViewBuilder

```swift
.accessibilityActions {
    Button("Archive") { archive(item) }
    Button("Share") { share(item) }
}
```

### `.accessibilityAdjustableAction(_:)` — Increment / Decrement

For custom sliders, steppers, or any value that increases/decreases.

```swift
CustomRatingView(rating: $rating)
    .accessibilityLabel("Rating")
    .accessibilityValue("\(rating) out of 5 stars")
    .accessibilityAdjustableAction { direction in
        switch direction {
        case .increment: rating = min(5, rating + 1)
        case .decrement: rating = max(0, rating - 1)
        @unknown default: break
        }
    }
```

### `.accessibilityScrollAction(_:)` — Scroll Direction

For custom scrollable content that doesn't use native `ScrollView`.

```swift
.accessibilityScrollAction { edge in
    switch edge {
    case .top: scrollToTop()
    case .bottom: scrollToBottom()
    case .leading: scrollLeft()
    case .trailing: scrollRight()
    @unknown default: break
    }
}
```

### `.accessibilityZoomAction(_:)` — Zoom Gestures

For custom maps, image viewers, or zoom-capable content.

```swift
.accessibilityZoomAction { action in
    switch action.direction {
    case .zoomIn: scale *= 1.2
    case .zoomOut: scale /= 1.2
    @unknown default: break
    }
}
```

### `.accessibilityActivationPoint(_:)` — Custom Tap Target

When the accessible tap point differs from the visual center.

```swift
// Tap the bottom-center of a custom shape
.accessibilityActivationPoint(CGPoint(x: frame.midX, y: frame.maxY - 8))
```

### Drag and Drop

```swift
.accessibilityDragPoint(UnitPoint.center, description: "Drag to reorder")
.accessibilityDropPoint(UnitPoint.center, description: "Drop here to add")
```

---

## Grouping and Structure

### `.accessibilityElement(children:)`

**`.combine`** — Merges all child elements into one, reading their labels in order. Use for related UI that makes more sense as a single unit.

```swift
// ✅ Rating row read as "4.5 stars, 2,304 reviews"
HStack {
    Image(systemName: "star.fill")
    Text("4.5")
    Text("(2,304 reviews)")
}
.accessibilityElement(children: .combine)
.accessibilityLabel("4.5 stars, 2,304 reviews")
```

**`.contain`** — Groups elements but still exposes each child individually. Used for containers that need a group label while preserving child navigability.

**`.ignore`** — Hides all children from VoiceOver. Use for decorative containers.

```swift
// Decorative divider container
HStack {
    Divider()
    Text("OR")
    Divider()
}
.accessibilityElement(children: .ignore)
.accessibilityLabel("Or")
```

### `.accessibilityChildren(_:)` — Explicit Child List

Provides a custom child list, overriding the default tree.

```swift
.accessibilityChildren {
    ForEach(items) { item in
        Text(item.title)
    }
}
```

### `.accessibilityHidden(_:)`

```swift
Image("decorative-background")
    .accessibilityHidden(true)

// Conditionally hide
Text(status)
    .accessibilityHidden(!isVisible)
```

### `.accessibilitySortPriority(_:)`

Higher values are read first. Default is 0.

```swift
VStack {
    Text("Summary").accessibilitySortPriority(2)     // read first
    Text("Details").accessibilitySortPriority(1)      // read second
    DismissButton().accessibilitySortPriority(-1)      // read last
}
```

## Focus Management

### `@AccessibilityFocusState` + `.accessibilityFocused(_:)`

Programmatically move VoiceOver focus to a specific element.

```swift
@AccessibilityFocusState private var isConfirmFocused: Bool

Button("Delete") { showConfirm = true }

if showConfirm {
    ConfirmationView()
        .accessibilityFocused($isConfirmFocused)
        .onAppear { isConfirmFocused = true }
}
```

### With Enum (Multiple Elements)

```swift
enum FormField { case name, email, password }

@AccessibilityFocusState private var focusedField: FormField?

TextField("Name", text: $name)
    .accessibilityFocused($focusedField, equals: .name)

// Move focus programmatically
Button("Next") { focusedField = .email }
```

### `.accessibilityDefaultFocus(_:_:)`

Sets which element receives focus by default when a view appears (iOS 17+).

```swift
VStack {
    HeaderView()
    PrimaryButton().accessibilityDefaultFocus($isDefault, true)
    SecondaryButton()
}
```

### `.accessibilityChildrenInNavigationOrder(_:)` — Explicit Order

Overrides default navigation order with an explicit sequence.

```swift
.accessibilityChildrenInNavigationOrder([heading, body, footer])
```

---

## Custom Rotors

The VoiceOver rotor lets users jump between elements of a specific type. Custom rotors add app-specific navigation.

### Basic Custom Rotor

```swift
.accessibilityRotor("Unread Messages") {
    ForEach(messages.filter(\.isUnread)) { message in
        AccessibilityRotorEntry(message.preview, id: message.id)
    }
}
```

### Text-Range Rotor

Navigates through ranges within a `Text` element.

```swift
Text(articleBody)
    .accessibilityRotor("Links") {
        ForEach(links) { link in
            AccessibilityRotorEntry(link.text, textRange: link.range)
        }
    }
```

### `accessibilityRotorEntry(id:in:)` — Stand-alone Entry

```swift
ForEach(headings) { heading in
    Text(heading.text)
        .font(.headline)
        .accessibilityAddTraits(.isHeader)
        .accessibilityRotorEntry(id: heading.id, in: headingNamespace)
}
```

---

## Announcements and Live Regions

### Post an Announcement

Use when a change happens that isn't in the view hierarchy (e.g., background upload completes).

```swift
// iOS 17+ (preferred)
AccessibilityNotification.Announcement("Upload complete").post()

// Older syntax
UIAccessibility.post(notification: .announcement, argument: "Upload complete")
```

### Screen Changed (Full Navigation Reset)

Post when the entire screen content changes (e.g., pushing a new view manually).

```swift
AccessibilityNotification.ScreenChanged().post()
// Or with a specific element to focus:
AccessibilityNotification.ScreenChanged(nil).post() // system default focus
```

### Layout Changed (Partial Update)

Post when part of the screen changes (e.g., a section expands, items load).

```swift
AccessibilityNotification.LayoutChanged().post()
```

### Live Region — `.updatesFrequently`

For labels that update continuously (timers, stock prices, status indicators). VoiceOver re-reads when value changes.

```swift
Text(timerLabel)
    .accessibilityAddTraits(.updatesFrequently)
    .accessibilityLabel("Time remaining: \(timerLabel)")
```

---

## Speech Modifiers

Control how VoiceOver speaks a specific element's text.

```swift
Text("Chapter 1: The Beginning")
    .speechAlwaysIncludesPunctuation()    // always read punctuation marks

Text("A.I.")
    .speechSpellsOutCharacters()          // spell out: "A dot I dot"

Text("Error: invalid input")
    .speechAdjustedPitch(0.5)            // lower pitch for errors (0.0–2.0)

// Queue announcements instead of interrupting
Text(statusMessage)
    .speechAnnouncementsQueued()
```

---

## Advanced Modifiers

### `.accessibilityCustomContent(_:_:importance:)` — Chunked Information

Delivers additional content through the VoiceOver "More Content" rotor. Useful for complex items (contacts, emails) where not all info should be read at once.

```swift
ContactRow(contact: contact)
    .accessibilityLabel(contact.fullName)
    .accessibilityCustomContent("Phone", contact.phoneNumber, importance: .high)
    .accessibilityCustomContent("Email", contact.email)
    .accessibilityCustomContent("Company", contact.company, importance: .default)
```

### `.accessibilityRepresentation(representation:)` — Replace AX Tree

Replaces the entire VoiceOver subtree with a different view's tree. Use for complex custom controls.

```swift
CustomSlider(value: $value, range: 0...100)
    .accessibilityRepresentation {
        Slider(value: $value, in: 0...100)
            .accessibilityLabel("Brightness")
    }
```

### `.accessibilityTextContentType(_:)` — Reading Style

Hints to VoiceOver how to read text (speech rate, pausing).

```swift
Text(poemBody)
    .accessibilityTextContentType(.poetry)

// Available types: plain, fileSystem, messaging, narrative,
// poetry, reading, sourceCode, spreadsheet, wordProcessing
```

### `.accessibilityHeading(_:)` — Heading Level

```swift
Text("Section Title")
    .accessibilityAddTraits(.isHeader)
    .accessibilityHeading(.h2)
```

### `.accessibilityIgnoresInvertColors(_:)` — Smart Invert Protection

Prevents the view from inverting colors when Smart Invert is enabled. Always apply to images, videos, and maps.

```swift
AsyncImage(url: url) { image in
    image.resizable()
}
.accessibilityIgnoresInvertColors()
```

### `.accessibilityShowsLargeContentViewer()` — Large Content Viewer

For UI elements that cannot scale with Dynamic Type (tab bars, toolbars). Shows a large version when long-pressed.

```swift
// Tab bar item that can't grow
Label("Library", systemImage: "books.vertical")
    .accessibilityShowsLargeContentViewer()

// Custom version with explicit content
TabItem()
    .accessibilityShowsLargeContentViewer {
        Label("Library", systemImage: "books.vertical")
    }
```

### `.accessibilityDirectTouch(_:options:)` — Pass-Through Gestures

For views that need raw touch input (drawing canvas, piano keys) even when VoiceOver is active.

```swift
DrawingCanvas()
    .accessibilityLabel("Drawing canvas")
    .accessibilityDirectTouch(.automatic, options: .silenceOnTouch)
```

### `.accessibilityChartDescriptor(_:)` — Chart Accessibility

Provides a full data description for charts (Swift Charts and custom charts).

```swift
Chart(data) { item in
    BarMark(x: .value("Month", item.month), y: .value("Sales", item.sales))
}
.accessibilityChartDescriptor(SalesChartDescriptor(data: data))

// Descriptor conformance:
struct SalesChartDescriptor: AXChartDescriptorRepresentable {
    let data: [SalesData]
    func makeChartDescriptor() -> AXChartDescriptor {
        AXChartDescriptor(
            title: "Monthly Sales",
            summary: "Sales increased 23% year-over-year",
            xAxis: AXCategoricalDataAxisDescriptor(title: "Month", categoryOrder: months),
            yAxis: AXNumericDataAxisDescriptor(title: "Revenue", range: 0...maxValue, gridlinePositions: []),
            series: [AXDataSeriesDescriptor(name: "Sales", isContinuous: false, dataPoints: points)]
        )
    }
}
```

---

## Common Mistakes

| Mistake | Fix |
|---|---|
| Missing label on icon button | Add `.accessibilityLabel("Share")` |
| Label includes control type: "Save button" | Just "Save" — VoiceOver adds type |
| Label describes action: "Tap to delete" | Just "Delete" — hint describes result |
| Decorative image announced | Add `.accessibilityHidden(true)` |
| State in label: "Selected item" | Use `.accessibilityAddTraits(.isSelected)` |
| Nested `accessibilityElement(children: .combine)` | Only one level; flatten the structure |
| No trait on custom tappable view | Add `.accessibilityAddTraits(.isButton)` |
| Long-press menu with no VoiceOver equivalent | Add `.accessibilityAction(named:)` for each item |
| `accessibilityValue` duplicates label | Value is for dynamic data only |
| Hardcoded string in `accessibilityLabel` | Use `LocalizedStringKey` or `Text` for localization |
| Announcement in `body` on every render | Post announcements in response to events, not on render |
