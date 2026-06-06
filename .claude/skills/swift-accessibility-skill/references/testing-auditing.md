# Testing and Auditing

Covers Accessibility Inspector, SwiftUI Previews, XCTest / XCUITest, manual testing procedures, and common audit findings — for verifying Accessibility Nutrition Label readiness.

## Contents
- [Accessibility Inspector (Xcode)](#accessibility-inspector-xcode)
- [Verifying Accessibility in Xcode](#verifying-accessibility-in-xcode)
- [XCUITest — Automated Accessibility Testing](#xcuitest--automated-accessibility-testing)
- [Manual Testing Checklist](#manual-testing-checklist)
- [Common Audit Findings](#common-audit-findings)

---

## Accessibility Inspector (Xcode)

The primary tool for inspecting and auditing accessibility without a real device. Available via Xcode → Open Developer Tool → Accessibility Inspector.

### Inspection Mode

Point at any element in the Simulator or on a connected Mac app. Inspector shows:
- `accessibilityLabel`, `accessibilityHint`, `accessibilityValue`
- `accessibilityTraits` (button, header, selected, etc.)
- `accessibilityFrame` (tap target size in points)
- Container information

**Usage:** Click the crosshair icon, then hover over elements in the Simulator. Verify that every element reports the correct label and traits. Confirm tap targets are ≥ 44×44pt.

### Audit Tab

Runs automated checks across the current screen.

```
Accessibility Inspector → Audit → Run Audit
```

Findings include:
- Missing labels on interactive elements
- Low color contrast (compares against WCAG thresholds)
- Touch targets below 44×44pt
- Elements with traits that contradict their role
- Decorative images exposed to accessibility tree

**Workflow:** Fix every finding before proceeding to manual testing. Treat high-severity findings as blockers.

### Contrast Checker

```
Accessibility Inspector → Inspection → Color tab → Use eyedropper
```

Measures contrast ratio between two colors. Validates against:
- 4.5:1 for normal text
- 3:1 for large text and non-text interactive elements

Test every color pair: foreground/background for body text, button labels, placeholder text, and state indicators.

### Settings Tab (Simulate Accessibility Settings)

Simulate device settings without changing actual device configuration:
- Increase Contrast
- Reduce Motion
- Bold Text
- Button Shapes
- Reduce Transparency
- Grayscale (via Simulator)
- Dynamic Type sizes

---

## Verifying Accessibility in Xcode

Use Xcode's built-in Canvas tools and Accessibility Inspector to test accessibility configurations without writing custom preview code. Many accessibility environment values (`colorSchemeContrast`, `accessibilityReduceMotion`, `accessibilityReduceTransparency`, `accessibilityDifferentiateWithoutColor`) are **read-only** — `.environment()` calls for these values compile but are **silently ignored** at runtime. Use Accessibility Inspector (Settings tab) or Simulator settings instead.

### Xcode Canvas Variants

The preview canvas has a **Variants** button (grid icon) at the bottom. Click it to choose:

| Variant mode | What it shows |
|---|---|
| **Dynamic Type Variants** | Your view rendered at all 12 Dynamic Type sizes side by side — catches clipping, overlap, and truncation |
| **Color Scheme Variants** | Light and dark mode previews — catches contrast failures and invisible borders |
| **Orientation Variants** | Portrait + landscape — catches layout breaks |

This is the fastest way to visually verify Dynamic Type and Dark Mode without writing any code.

### Xcode Canvas Device Settings

The preview canvas has a **Device Settings** button (slider icon) at the bottom. Use it to configure a single preview with:

- **Color Scheme**: light / dark
- **Dynamic Type size**: any of the 12 sizes
- **Orientation**: portrait / landscape

Combine these to test specific scenarios (e.g., dark mode + accessibility large text + landscape).

### Accessibility Inspector — Settings Tab

For read-only accessibility settings, use Accessibility Inspector on the Simulator:

**Open:** Xcode menu → Open Developer Tool → Accessibility Inspector

**Settings tab** — toggle these on the Simulator without changing device settings:

| Setting | What it simulates |
|---|---|
| Increase Contrast | Tests `colorSchemeContrast == .increased` |
| Reduce Motion | Tests `accessibilityReduceMotion == true` |
| Bold Text | Tests `legibilityWeight == .bold` |
| Reduce Transparency | Tests `accessibilityReduceTransparency == true` |
| Button Shapes | Tests `accessibilityShowButtonShapes == true` |
| Grayscale | Tests color-only indicators (via Simulator Color Filters) |
| Dynamic Type | Adjusts text size on the Simulator |

**Workflow:** Enable each setting, then interact with the Simulator to verify your UI adapts correctly.

### Writable environment values for `#Preview`

Only these accessibility-related values are writable and work in `#Preview` with `.environment()`:

```swift
#Preview("Large Text") {
    ProductCardView(product: .sample)
        .environment(\.dynamicTypeSize, .accessibility3)
}

#Preview("Dark Mode") {
    ProductCardView(product: .sample)
        .environment(\.colorScheme, .dark)
}
```

For testing adaptive layout breakpoints:

```swift
#Preview("Before breakpoint") {
    AdaptiveCardView()
        .environment(\.dynamicTypeSize, .xxxLarge)
}

#Preview("After breakpoint") {
    AdaptiveCardView()
        .environment(\.dynamicTypeSize, .accessibility1)
}
```

### What to check for each setting

| Setting | Check for |
|---|---|
| Dynamic Type (large sizes) | Text clipping, overlapping elements, truncated labels without `...` affordance |
| Dark Mode | Unreadable text, invisible borders, low-contrast icons |
| Increase Contrast | Borders/separators visible, text contrast improved |
| Reduce Motion | No animations playing, state changes still visible via opacity/fade |
| Grayscale | Status indicators still distinguishable by shape/icon/text |
| Bold Text | Layout doesn't break with heavier font weights |

---

## XCUITest — Automated Accessibility Testing

### Finding Elements by Accessibility Identifier

```swift
// Set stable identifiers in production code
TextField("Search", text: $query)
    .accessibilityIdentifier("searchField")

Button("Submit") { submit() }
    .accessibilityIdentifier("submitButton")

// Find in UI tests
func testSearchFlow() throws {
    let app = XCUIApplication()
    app.launch()

    let searchField = app.textFields["searchField"]
    XCTAssert(searchField.exists, "Search field must exist")
    XCTAssert(searchField.isEnabled, "Search field must be enabled")

    searchField.tap()
    searchField.typeText("accessibility")

    let submitButton = app.buttons["submitButton"]
    XCTAssert(submitButton.exists)
    submitButton.tap()
}
```

### Querying by Accessibility Label

```swift
// Find by label (matches accessibilityLabel)
let shareButton = app.buttons["Share"]
XCTAssert(shareButton.exists)

// Find by partial label
let deleteButtons = app.buttons.matching(identifier: "Delete")
XCTAssert(deleteButtons.count > 0)
```

### Printing the Accessibility Tree

```swift
// Invaluable for debugging — prints full accessible element tree
func testPrintTree() {
    let app = XCUIApplication()
    app.launch()
    print(app.debugDescription)
}
```

### Verifying Accessibility Properties

```swift
func testProductCardAccessibility() throws {
    let app = XCUIApplication()
    app.launch()

    // Verify the card is a single accessible element
    let card = app.otherElements["Product Card"]
    XCTAssert(card.exists)

    // Verify label is meaningful
    XCTAssertFalse(card.label.isEmpty, "Card must have an accessibility label")

    // Verify interactive elements have labels
    let favoriteButton = app.buttons["Add to favorites"]
    XCTAssert(favoriteButton.exists, "Favorite button must have correct label")

    // Verify button is large enough (indirectly via existence and interaction)
    XCTAssert(favoriteButton.isHittable, "Favorite button must be tappable")
}
```

### Testing VoiceOver Navigation Flow

```swift
func testVoiceOverReadingOrder() {
    let app = XCUIApplication()
    app.launchArguments = ["-UIAccessibilityEnabled", "YES"]
    app.launch()

    // Swipe through elements and verify order
    // Note: full VoiceOver simulation is limited in XCUITest
    // Use Accessibility Inspector + manual testing for complete VoiceOver verification
}
```

### performAccessibilityAudit() (iOS 17+ / macOS 14+ / tvOS 17+ / watchOS 10+ / visionOS 1+)

Runs Accessibility Inspector's audit engine programmatically inside XCUITest. Catches accessibility regressions automatically in CI — no manual inspection needed. Part of the `XCUIAutomation` framework.

#### API Signature

```swift
@MainActor func performAccessibilityAudit(
    for auditTypes: XCUIAccessibilityAuditType = .all,
    _ issueHandler: ((XCUIAccessibilityAuditIssue) throws -> Bool)? = nil
) throws
```

#### Audit Types

| Type | What it checks | Platforms |
|---|---|---|
| `.contrast` | WCAG contrast ratio (4.5:1 text, 3:1 non-text) | All |
| `.elementDetection` | Elements missing from the accessibility tree | All |
| `.hitRegion` | Touch targets smaller than 44×44pt | All |
| `.sufficientElementDescription` | Missing or empty accessibility labels | All |
| `.dynamicType` | Text that doesn't scale with Dynamic Type | All |
| `.textClipped` | Text clipped or truncated at larger sizes | All |
| `.trait` | Incorrect or missing accessibility traits | All |
| `.action` | Missing or invalid accessibility actions | macOS only |
| `.parentChild` | Parent-child relationship issues in the accessibility tree | macOS only |

#### XCUIAccessibilityAuditIssue Properties

| Property | Type | Description |
|---|---|---|
| `auditType` | `XCUIAccessibilityAuditType` | The audit type that flagged this issue |
| `element` | `XCUIElement?` | The element with the issue (nil if not identifiable) |
| `compactDescription` | `String` | Short description of the issue |
| `detailedDescription` | `String` | Full description with remediation guidance |

#### Basic Usage — Run All Checks

```swift
func testAccessibilityAudit() throws {
    let app = XCUIApplication()
    app.launch()

    // Runs all audit types — fails test on any issue
    try app.performAccessibilityAudit()
}
```

#### Filter by Audit Type

```swift
func testContrastAndLabels() throws {
    let app = XCUIApplication()
    app.launch()

    // Run only contrast and label checks
    try app.performAccessibilityAudit(for: [.contrast, .sufficientElementDescription])
}
```

#### Ignore Known Issues

Use the issue handler closure to suppress known issues. Return `true` to ignore an issue, `false` to fail on it. Use `compactDescription` or `detailedDescription` for debugging.

```swift
func testAccessibilityAuditWithExclusions() throws {
    let app = XCUIApplication()
    app.launch()

    try app.performAccessibilityAudit(for: .all) { issue in
        // Log issue details for debugging
        print(issue.detailedDescription)

        // Ignore contrast issues on the splash screen (uses branded colors)
        if issue.auditType == .contrast,
           issue.element?.identifier == "splashLogo" {
            return true
        }
        return false
    }
}
```

#### Exclude Specific Audit Types

```swift
func testAccessibilityAuditExcludingContrast() throws {
    let app = XCUIApplication()
    app.launch()

    var auditTypes: XCUIAccessibilityAuditType = .all
    auditTypes.remove(.contrast) // Skip contrast checks

    try app.performAccessibilityAudit(for: auditTypes)
}
```

#### Multi-Screen Regression Test

Use a UI test like this to audit several important screens in one run.
The test launches the app, navigates through key flows, and runs `performAccessibilityAudit()` after each navigation step.
This helps catch common regressions such as missing labels, low contrast, clipped text, small hit regions, and incorrect traits.

```swift
class AccessibilityRegressionTests: XCTestCase {
    func testFullAccessibilityAudit() throws {
        let app = XCUIApplication()
        app.launch()

        // Audit the launch screen.
        try app.performAccessibilityAudit()

        // Navigate to Settings and audit that screen.
        app.tabBars.buttons["Settings"].tap()
        try app.performAccessibilityAudit()

        // Navigate to Profile and audit that screen.
        app.tabBars.buttons["Profile"].tap()
        try app.performAccessibilityAudit()
    }
}
```

This does not replace manual testing with VoiceOver, Voice Control, Switch Control, or real-device checks.
It only audits the screens the test actually visits, so extend the navigation flow to cover the important user paths in your app.

---

## Manual Testing Checklist

### VoiceOver Testing (Requires Real Device)

Enable: Settings → Accessibility → VoiceOver

| Test | Pass Criteria |
|---|---|
| Swipe right through all elements | Every interactive element is reachable |
| Tap any element | Label, value, and traits are announced |
| Double-tap interactive element | Correct action performed |
| Swipe up/down on adjustable element | Value changes (sliders, steppers) |
| Two-finger Z gesture on modal | Modal dismisses |
| Rotor navigation | Headings, links, actions all navigable |
| "Read All" (two-finger swipe up) | Reads entire screen in logical order |
| Focus after navigation push | Focus moves to first element in new screen |
| Focus after modal dismiss | Focus returns to trigger element |

**Critical flows to test:**
1. Complete main user task start-to-finish with VoiceOver
2. Login / account creation
3. Key purchase or data-entry flow
4. Settings changes

### Voice Control Testing (Requires Real Device)

Enable: Settings → Accessibility → Voice Control

| Test | Pass Criteria |
|---|---|
| "Show numbers" | Every interactive element has a number |
| "Tap [number]" | Activates correct element |
| "Show names" | Every element shows a visible text label |
| "Tap [label]" | Activates element by voice |
| "Type [text]" | Inserts text in active field |
| "Select [word]" | Selects matching text |
| "Delete that" | Deletes selected text |
| "Scroll down/up" | Scrolls the content |

### Switch Control Testing (Requires Real Device or Setting)

Enable: Settings → Accessibility → Switch Control

| Test | Pass Criteria |
|---|---|
| Item scanning | Every element is highlighted in turn |
| Group scanning | Related groups highlighted as units |
| Select highlighted element | Correct action triggered |
| Custom actions available | Actions appear in scanning menu |
| No timed interactions | No UI times out or auto-advances |

### Full Keyboard Access (iPad/Mac)

Enable: Settings → Accessibility → Keyboards → Full Keyboard Access

| Test | Pass Criteria |
|---|---|
| Tab key | Focus moves forward through all interactive elements |
| Shift+Tab | Focus moves backward |
| Space/Return | Activates focused element |
| Escape | Dismisses modal / cancels |
| Arrow keys | Navigates within pickers, sliders |
| No focus gaps | Focus never gets stuck in a dead zone |

### Dynamic Type

Enable: Settings → Accessibility → Display & Text Size → Larger Text → Enable Larger Accessibility Sizes

| Size | Test |
|---|---|
| Small | Text readable, no clipping |
| Large (default) | Normal experience |
| Accessibility Large | Layout adapts, no overlap |
| Accessibility 5 (max) | All content accessible, nothing truncated without affordance |

### Grayscale (Differentiate Without Color)

Enable: Settings → Accessibility → Display & Text Size → Color Filters → Grayscale

| Test | Pass Criteria |
|---|---|
| Status indicators | Still meaningful in grayscale |
| Charts and graphs | Data distinguishable by shape/position |
| Error states | Clearly distinguishable from success |
| All UI | No information lost in grayscale |

### Reduce Motion

Enable: Settings → Accessibility → Motion → Reduce Motion

| Test | Pass Criteria |
|---|---|
| Navigation transitions | No sliding; dissolve/fade instead |
| Animations on state change | Either removed or replaced with fade |
| Auto-playing content | Stopped or manual control provided |
| Loading animations | Replaced or removed |

### Dark Mode + Increase Contrast

Enable: Settings → Appearance → Dark, AND Settings → Accessibility → Display & Text Size → Increase Contrast

| Test | Pass Criteria |
|---|---|
| All text | Readable against dark background |
| Borders and separators | Visible |
| Status indicators | High contrast |
| Images on dark background | No white halo effect |

---

## Common Audit Findings

| Finding | Severity | Detection | Fix |
|---|---|---|---|
| Missing label on icon button | Blocks Assistive Tech | Accessibility Inspector → Missing label warning | `.accessibilityLabel("Share")` |
| Decorative image announced | Degrades Experience | VO reads image name or "image" | `.accessibilityHidden(true)` |
| Touch target < 44pt | Degrades Experience | Inspector → Accessibility Frame < 44×44 | `.frame(minWidth: 44, minHeight: 44)` or `.contentShape` |
| State embedded in label | Degrades Experience | Inspector → label changes on toggle | Use `.accessibilityAddTraits(.isSelected)` |
| Wrong reading order | Degrades Experience | VO navigation mismatches visual | `.accessibilitySortPriority` or `accessibilityElements` |
| Color-only status indicator | Incomplete Support | Grayscale filter test | Add shape/icon/text redundancy |
| Text contrast fails dark mode | Incomplete Support | Inspector contrast checker | Use semantic colors, test both modes |
| Animation with Reduce Motion | Incomplete Support | Enable Reduce Motion, check for motion | Gate `withAnimation` or provide `.opacity` transition |
| No custom rotor for long lists | Incomplete Support | VoiceOver navigation test | Add `accessibilityRotor` |
| Modal doesn't trap VoiceOver | Blocks Assistive Tech | VO can reach background content | `accessibilityViewIsModal = true` |
| No focus movement after push | Degrades Experience | VO stays on previous screen | Post `.screenChanged` after navigation |
| Custom text truncates at any size | Incomplete Support | Dynamic Type max size test | `fixedSize()` → scroll, or adaptive layout |
| Missing `accessibilityPerformEscape` | Blocks Assistive Tech | VO two-finger Z doesn't dismiss | Implement `accessibilityPerformEscape()` |
| Voice Control element missing | Blocks Assistive Tech | "Show numbers" test | Use `Button` or add `.accessibilityTraits(.button)` |
| Hint describes action not result | Degrades Experience | Listen to VO hint announcement | Rewrite: "Saves your changes" not "Tap to save" |

> **Automation tip:** `performAccessibilityAudit()` (iOS 17+) automatically detects missing labels, low contrast, small hit regions, clipped text, missing traits, and Dynamic Type failures. Run it in CI to catch most of these findings before manual testing.
