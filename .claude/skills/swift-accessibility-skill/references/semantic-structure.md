# Semantic Structure

Covers grouping, reading order, focus management, custom rotors, modal focus trapping, and heading hierarchy — the structural layer of accessibility that determines how assistive technologies navigate and understand your UI.

## Contents
- [Grouping Elements](#grouping-elements)
- [Reading Order and Sort Priority](#reading-order-and-sort-priority)
- [Focus Management](#focus-management)
- [Custom Rotors](#custom-rotors)
- [Modal Focus Trapping](#modal-focus-trapping)
- [Heading Hierarchy](#heading-hierarchy)
- [UIAccessibilityContainer (UIKit)](#uiaccessibilitycontainer-uikit)
- [Common Mistakes](#common-mistakes)

---

## Grouping Elements

### SwiftUI: `.accessibilityElement(children:)`

Controls how VoiceOver exposes a container's children.

**`.combine`** — Merges all descendants into one element. VoiceOver reads their labels in order. Best for related content that forms a single semantic unit.

```swift
// ✅ Read as "4.5 stars, 2,304 ratings"
HStack {
    Image(systemName: "star.fill").accessibilityHidden(true)
    Text("4.5")
    Text("(2,304 ratings)")
}
.accessibilityElement(children: .combine)
// Provide an explicit label when auto-combined text isn't natural:
// .accessibilityLabel("4.5 stars, 2,304 ratings")

// ✅ Product card read as a single element
VStack(alignment: .leading) {
    Text(product.name)
    Text(product.price, format: .currency(code: "USD"))
    Text(product.stock > 0 ? "In stock" : "Out of stock")
}
.accessibilityElement(children: .combine)
```

**`.contain`** — Groups elements, exposes each child individually. Use for containers that need a group label while preserving child navigability (e.g., grouped form sections).

```swift
// ✅ Group sidebar — users can skip the whole group with Switch Control
SidebarView()
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Sidebar navigation")
```

**`.ignore`** — Hides all children from VoiceOver. The container itself becomes the element (or is hidden if no label). Use for purely decorative compositions.

```swift
// ✅ Decorative separator with text
HStack {
    Divider()
    Text("OR")
    Divider()
}
.accessibilityElement(children: .ignore)
.accessibilityLabel("Or")  // expose the semantic meaning

// ✅ Purely decorative — expose nothing
BackgroundAnimationView()
    .accessibilityHidden(true)  // simpler than .ignore for full hiding
```

### Explicit Custom Children

```swift
// Provide a completely custom child list
.accessibilityChildren {
    ForEach(filteredItems) { item in
        Text(item.title)
    }
}
```

### UIKit: `shouldGroupAccessibilityChildren`

Groups all children into a single Switch Control scanning unit. Does NOT merge elements for VoiceOver navigation (VoiceOver still reads each child individually).

```swift
// ✅ Switch Control: skip entire sidebar with one tap
sidebarView.shouldGroupAccessibilityChildren = true
sidebarView.accessibilityLabel = "Sidebar navigation"

// ✅ Container exposes ordered children to VoiceOver
class CardView: UIView {
    override var isAccessibilityElement: Bool {
        get { false }  // container is NOT an element
        set { }
    }
    override var accessibilityElements: [Any]? {
        get { [titleLabel, priceLabel, addButton] }
        set { }
    }
}
```

---

## Reading Order and Sort Priority

VoiceOver reads elements in the order they appear in the accessibility tree, which usually follows the view hierarchy and layout direction. Override when visual and semantic order differ.

### SwiftUI: `.accessibilitySortPriority(_:)`

Higher values are read first. Default is 0. Negative values push elements to the end.

```swift
// ✅ Ensure critical info is read before decorative content
VStack {
    Text("Error: Payment failed")
        .accessibilitySortPriority(2)       // read first
    Image(systemName: "exclamationmark.circle")
        .accessibilityHidden(true)          // decorative
    Text("Please update your payment method")
        .accessibilitySortPriority(1)       // read second
    DismissButton()
        .accessibilitySortPriority(-1)      // read last
}
```

### SwiftUI: `.accessibilityChildrenInNavigationOrder(_:)`

Provides an explicit, ordered list of identifiers for navigation. Use when sort priority alone isn't sufficient.

```swift
@Namespace var navOrder

var body: some View {
    ZStack {
        ContentView()
            .accessibilityElement(id: "content", namespace: navOrder)
        HeaderView()
            .accessibilityElement(id: "header", namespace: navOrder)
        FooterView()
            .accessibilityElement(id: "footer", namespace: navOrder)
    }
    .accessibilityChildrenInNavigationOrder(["header", "content", "footer"], namespace: navOrder)
}
```

### UIKit: `accessibilityElements` Array

The order of elements in `accessibilityElements` dictates VoiceOver navigation order.

```swift
class DashboardView: UIView {
    override var accessibilityElements: [Any]? {
        get {
            // Explicitly control reading order
            [headerView, alertBanner, contentArea, actionButton]
        }
        set { }
    }
}
```

---

## Focus Management

### SwiftUI: `@AccessibilityFocusState`

Programmatically move VoiceOver focus to a specific element. Essential when content appears dynamically (modals, error messages, state changes).

```swift
@AccessibilityFocusState private var isErrorFocused: Bool

var body: some View {
    VStack {
        TextField("Email", text: $email)

        if let error = validationError {
            Text(error)
                .foregroundStyle(.red)
                .accessibilityFocused($isErrorFocused)
        }

        Button("Submit") {
            if let error = validate() {
                validationError = error
                isErrorFocused = true  // VoiceOver jumps to error
            }
        }
    }
}
```

### Multiple Focus Targets

```swift
enum FormField { case name, email, password }

@AccessibilityFocusState private var focusedField: FormField?

var body: some View {
    VStack {
        TextField("Name", text: $name)
            .accessibilityFocused($focusedField, equals: .name)
        TextField("Email", text: $email)
            .accessibilityFocused($focusedField, equals: .email)
        SecureField("Password", text: $password)
            .accessibilityFocused($focusedField, equals: .password)

        Button("Next") {
            // Move focus programmatically
            switch focusedField {
            case .name: focusedField = .email
            case .email: focusedField = .password
            default: submit()
            }
        }
    }
}
```

### `.accessibilityDefaultFocus(_:_:)` — Initial Focus (iOS 17+)

Sets which element receives focus when a view first appears.

```swift
@AccessibilityFocusState private var isDefaultFocused: Bool

AlertView()
    .onAppear { isDefaultFocused = true }

// Within AlertView:
Button("Confirm") { confirm() }
    .accessibilityDefaultFocus($isDefaultFocused, true)
```

### UIKit: Moving Focus with Notifications

```swift
// Focus moves to a specific element (partial update)
UIAccessibility.post(notification: .layoutChanged, argument: errorLabel)

// Focus resets to start of new screen (full replacement)
UIAccessibility.post(notification: .screenChanged, argument: firstInteractiveElement)

// Announce a change without moving focus
UIAccessibility.post(notification: .announcement, argument: "Message sent")
```

**When to use each:**

| Notification | Use When |
|---|---|
| `.layoutChanged` | Part of the screen changes (row inserted, error appears, section expands) |
| `.screenChanged` | Entire content changes (modal appears, tab switched, navigation push) |
| `.announcement` | Background state change — no layout change occurred |
| `.pageScrolled` | Custom scroll view changed pages |

---

## Custom Rotors

The VoiceOver rotor (two-finger rotation gesture) lets users jump between elements of a specific type. Custom rotors add app-specific navigation shortcuts.

### SwiftUI: `accessibilityRotor(_:entries:)`

```swift
// ✅ Jump between unread messages
.accessibilityRotor("Unread Messages") {
    ForEach(messages.filter(\.isUnread)) { message in
        AccessibilityRotorEntry(message.preview, id: message.id)
    }
}

// ✅ Jump between search result matches in a document
Text(documentText)
    .accessibilityRotor("Search Results") {
        ForEach(searchHighlights) { match in
            AccessibilityRotorEntry(match.text, textRange: match.range)
        }
    }
```

### Rotor with Explicit Focus Targeting

```swift
@Namespace var headingNamespace

var body: some View {
    ScrollView {
        ForEach(article.sections) { section in
            VStack(alignment: .leading) {
                Text(section.heading)
                    .font(.title2)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityRotorEntry(id: section.id, in: headingNamespace)

                Text(section.body)
            }
        }
    }
    .accessibilityRotor("Headings", entries: article.sections, id: \.id, in: headingNamespace, label: \.heading)
}
```

### UIKit: `UIAccessibilityCustomRotor`

```swift
class ArticleViewController: UIViewController {
    var headings: [Heading] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        accessibilityCustomRotors = [makeHeadingRotor()]
    }

    private func makeHeadingRotor() -> UIAccessibilityCustomRotor {
        UIAccessibilityCustomRotor(name: "Headings") { [weak self] predicate in
            guard let self = self else { return nil }

            // Find current heading index
            let currentIndex = self.headings.firstIndex {
                $0.view === predicate.currentItem.targetElement as? UIView
            }

            let nextIndex: Int
            switch predicate.searchDirection {
            case .next:
                nextIndex = (currentIndex.map { $0 + 1 }) ?? 0
            case .previous:
                nextIndex = (currentIndex.map { $0 - 1 }) ?? (self.headings.count - 1)
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

## Modal Focus Trapping

When a modal, alert, or sheet appears, VoiceOver must stay within the modal. Users should not be able to swipe to background content.

### SwiftUI

SwiftUI `.sheet()`, `.alert()`, `.confirmationDialog()`, and `NavigationStack` modals handle focus trapping automatically.

```swift
// ✅ Focus trapped automatically
.sheet(isPresented: $showSettings) {
    SettingsView()  // VoiceOver stays within this view
}

// ✅ Post notification after manual presentation
.onChange(of: showCustomModal) { _, isShowing in
    if isShowing {
        // Give SwiftUI a moment to render, then move focus
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            AccessibilityNotification.ScreenChanged().post()
        }
    }
}
```

### UIKit: `accessibilityViewIsModal`

```swift
class CustomModalView: UIView {
    // Set this on the OUTERMOST modal view, not a child
    override var accessibilityViewIsModal: Bool {
        get { true }
        set { }
    }
}

func presentModal() {
    let modal = CustomModalView()
    view.addSubview(modal)

    // VoiceOver focus moves into the modal
    UIAccessibility.post(notification: .screenChanged, argument: modal)
    // VoiceOver now ignores all views behind the modal
}

// ✅ Support Escape: two-finger Z gesture (VoiceOver) / Escape key (Full Keyboard Access)
override func accessibilityPerformEscape() -> Bool {
    dismissModal()
    return true
}
```

**Critical pitfalls:**
- Setting `accessibilityViewIsModal` on a child view (not the container) — focus escapes to siblings
- Forgetting `accessibilityPerformEscape` — users cannot dismiss with VoiceOver gestures
- Not posting `.screenChanged` after presentation — VoiceOver stays focused on background

### Focus Return on Dismissal

```swift
// UIKit — return focus to the trigger after dismissing
@AccessibilityFocusState private var returnFocus: Bool  // SwiftUI equivalent

// UIKit: track the element that opened the modal
weak var presentingElement: UIView?

func dismissModal() {
    dismiss(animated: true) {
        // Return focus to the element that triggered the modal
        UIAccessibility.post(notification: .screenChanged, argument: self.presentingElement)
    }
}
```

---

## Heading Hierarchy

Headings let VoiceOver users navigate with the Headings rotor — jumping directly between sections.

### SwiftUI

```swift
// ✅ Mark section headers
Text("Account Settings")
    .font(.title2)
    .accessibilityAddTraits(.isHeader)

// ✅ Heading with level (iOS 17+)
Text("Chapter 1: Introduction")
    .accessibilityAddTraits(.isHeader)
    .accessibilityHeading(.h1)

Text("1.1 Getting Started")
    .accessibilityAddTraits(.isHeader)
    .accessibilityHeading(.h2)

// Available levels: .h1, .h2, .h3, .h4, .h5, .h6, .unspecified
```

### UIKit

```swift
// ✅ Header trait
sectionLabel.accessibilityTraits = [.header, .staticText]

// Heading levels are set via accessibilityHeading (tvOS/Mac) or traits on iOS
// iOS doesn't expose explicit heading levels through UIKit APIs —
// use accessibilityTraits = .header for all heading levels
```

### Document Structure Pattern

For document-like content (articles, settings pages, help content):

```swift
struct ArticleView: View {
    var article: Article

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Page title — h1
                Text(article.title)
                    .font(.largeTitle)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityHeading(.h1)

                ForEach(article.sections) { section in
                    // Section heading — h2
                    Text(section.title)
                        .font(.title2)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityHeading(.h2)

                    Text(section.body)

                    ForEach(section.subsections) { sub in
                        // Subsection heading — h3
                        Text(sub.title)
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityHeading(.h3)

                        Text(sub.body)
                    }
                }
            }
            .padding()
        }
    }
}
```

---

## UIAccessibilityContainer (UIKit)

For complex views where VoiceOver needs structured navigation within a single UIView.

### `accessibilityContainerType`

Provides semantic meaning to the container. VoiceOver announces entering/leaving based on type.

```swift
// Table container — VoiceOver says "table" when entering
tableContainerView.accessibilityContainerType = .dataTable

// List container — VoiceOver says "list"
listView.accessibilityContainerType = .list

// Landmark — like HTML landmarks
navContainerView.accessibilityContainerType = .landmark

// Semantic group — related content without a specific type
cardView.accessibilityContainerType = .semanticGroup
```

### `accessibilityNavigationStyle`

Controls how VoiceOver navigates within a container.

```swift
// .combined — children are navigated as a group (one element)
container.accessibilityNavigationStyle = .combined

// .separate — children are navigated individually (default for most containers)
container.accessibilityNavigationStyle = .separate

// .automatic — system chooses (default)
container.accessibilityNavigationStyle = .automatic
```

### Custom Element Ordering

```swift
class DashboardView: UIView {
    @IBOutlet var alertBanner: UIView!
    @IBOutlet var header: UIView!
    @IBOutlet var mainContent: UIView!
    @IBOutlet var actionButtons: UIView!

    override var isAccessibilityElement: Bool {
        get { false }   // Container is NOT itself an element
        set { }
    }

    override var accessibilityElements: [Any]? {
        get {
            // Alert banner first — critical content
            var elements: [Any] = []
            if alertBanner.isHidden == false {
                elements.append(alertBanner!)
            }
            elements.append(contentsOf: [header!, mainContent!, actionButtons!])
            return elements
        }
        set { }
    }
}
```

---

## Common Mistakes

| Mistake | Fix |
|---|---|
| Container `isAccessibilityElement = true` AND `accessibilityElements` set | Set `isAccessibilityElement = false` on containers that expose children |
| `.accessibilityElement(children: .combine)` nested inside another `.combine` | Flatten the structure — only one combine level |
| VoiceOver reads background content behind modal | Set `accessibilityViewIsModal = true` on the outermost modal view |
| No focus movement after modal appears | Post `.screenChanged` notification pointing to modal's first element |
| Reading order follows visual layout instead of semantic order | Use `.accessibilitySortPriority` or `accessibilityElements` to control order |
| No custom rotor for data-rich lists | Add `accessibilityRotor` for efficient navigation of long lists |
| Missing `.isHeader` trait on section headings | Every section title should have `.accessibilityAddTraits(.isHeader)` |
| No `accessibilityPerformEscape()` on custom modals | Implement to support two-finger Z gesture and Escape key |
| `accessibilityViewIsModal` on a child, not the root | Must be on the outermost modal container view |
| Focus lost after content update (async data loads) | Post `.layoutChanged` with the first new element as argument |
| `accessibilityElements` not invalidated after data change | Nil-out cache + post `.layoutChanged` when underlying data changes |
