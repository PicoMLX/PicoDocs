# Display Settings and Visual Accessibility

Covers four Accessibility Nutrition Label categories: **Reduced Motion**, **Sufficient Contrast**, **Dark Interface**, and **Differentiate Without Color**. Also covers Reduce Transparency, Bold Text, and Smart Invert.

## Contents
- [Reduce Motion](#reduce-motion)
- [Sufficient Contrast and Dark Interface](#sufficient-contrast-and-dark-interface)
- [Differentiate Without Color](#differentiate-without-color)
- [Reduce Transparency](#reduce-transparency)
- [Bold Text](#bold-text)
- [Smart Invert / Invert Colors](#smart-invert--invert-colors)
- [UIKit Notification Observation](#uikit-notification-observation)
- [Common Failures](#common-failures)

---

## Reduce Motion

Users with vestibular disorders enable Reduce Motion to avoid nausea, dizziness, or headaches from certain animations. **Animations must not be ignored — they must be appropriately replaced.**

### Detection

```swift
// SwiftUI
@Environment(\.accessibilityReduceMotion) var reduceMotion

// UIKit
UIAccessibility.isReduceMotionEnabled

// watchOS
WKAccessibilityIsReduceMotionEnabled()
```

### Decision Tree

**Is the animation purely decorative?** (e.g., a bouncing logo, a particle effect)
→ Remove it entirely when Reduce Motion is enabled.

**Does the animation convey meaning?** (e.g., a card slides into a stack to show it was saved, a view zooms in to show hierarchy)
→ Replace with a motion-free alternative: fade, dissolve, highlight, color change.
→ Never remove — removing breaks comprehension.

### SwiftUI Patterns

```swift
// ✅ Pattern 1: Gate withAnimation
@Environment(\.accessibilityReduceMotion) var reduceMotion

Button("Show Detail") {
    if reduceMotion {
        isVisible = true    // instant — no animation
    } else {
        withAnimation(.spring()) { isVisible = true }
    }
}

// ✅ Pattern 2: Conditional animation modifier
Text("Status: \(status)")
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: status)

// ✅ Pattern 3: Cross-fade instead of slide
if reduceMotion {
    content.transition(.opacity)      // fade — safe
} else {
    content.transition(.slide)        // slide — may cause issues
}
```

### UIKit Patterns

```swift
// ✅ Check before animating
func showCard() {
    if UIAccessibility.isReduceMotionEnabled {
        cardView.alpha = 1           // instant appearance
    } else {
        UIView.animate(withDuration: 0.3) {
            self.cardView.alpha = 1
        }
    }
}

// ✅ Observe runtime changes
NotificationCenter.default.addObserver(
    forName: UIAccessibility.reduceMotionStatusDidChangeNotification,
    object: nil, queue: .main
) { _ in
    self.updateAnimationPreferences()
}
```

### Auto-Advancing Content

Carousels, slideshows, and auto-playing content must either stop or provide a manual control.

```swift
struct AutoScrollBanner: View {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State private var currentIndex = 0

    var body: some View {
        TabView(selection: $currentIndex) {
            ForEach(banners.indices, id: \.self) { index in
                BannerView(banner: banners[index]).tag(index)
            }
        }
        .tabViewStyle(.page)
        .onAppear {
            if !reduceMotion { startAutoScroll() }
        }
        .onChange(of: reduceMotion) { _, newValue in
            if newValue { stopAutoScroll() }
        }
    }
}
```

### Nutrition Label Criteria

To indicate **Reduced Motion** support:
- Parallax, depth simulation, animated blur → disabled
- Spinning/vortex/multi-axis motion → removed or replaced
- Auto-advancing content → stopped or manual control provided
- Meaningful animations → replaced (not removed) with fade/dissolve/color shift
- System setting detected automatically (no in-app setting required)

---

## Sufficient Contrast and Dark Interface

### WCAG Contrast Ratios

| Element | Minimum Ratio | Enhanced (WCAG AAA) |
|---|---|---|
| Normal text (<18pt regular, <14pt bold) | **4.5:1** | 7:1 |
| Large text (≥18pt regular or ≥14pt bold) | **3:1** | 4.5:1 |
| Non-text interactive elements | **3:1** | — |
| State indicators (checkbox border) | **3:1** | — |
| Decorative text with no informational value | None required | — |

### Semantic Colors — Always Adapt

Use semantic colors that automatically adapt to light/dark mode and Increase Contrast.

```swift
// SwiftUI — semantic colors adapt automatically
Text("Primary content")
    .foregroundStyle(.primary)            // black in light, white in dark

Text("Secondary content")
    .foregroundStyle(.secondary)          // gray, higher contrast when needed

Rectangle()
    .fill(Color(.systemBackground))       // white/black

// ❌ Avoid hardcoded colors — don't adapt
Text("Label")
    .foregroundStyle(Color(red: 0.5, green: 0.5, blue: 0.5))  // might fail in dark mode
```

```swift
// UIKit — UIColor semantic variants
label.textColor = .label              // adapts to light/dark
label.textColor = .secondaryLabel     // adapts
view.backgroundColor = .systemBackground
view.backgroundColor = .secondarySystemBackground
```

### Custom Colors with Dark Mode Support

```swift
// SwiftUI — Color Set with dark variant in asset catalog
Color("BrandPrimary")   // define Light and Dark in Assets.xcassets

// SwiftUI does not provide an inline light/dark Color initializer.
// Prefer Color Sets for app-defined adaptive colors.

// UIKit — dynamic color
let brandColor = UIColor { traits in
    traits.userInterfaceStyle == .dark
        ? UIColor(red: 0.0, green: 0.7, blue: 1.0, alpha: 1)   // light blue on dark
        : UIColor(red: 0.0, green: 0.4, blue: 0.8, alpha: 1)   // darker blue on light
}
```

### Increase Contrast

```swift
// SwiftUI
@Environment(\.colorSchemeContrast) var contrast
let increaseContrast = (contrast == .increased)

// Example: boost border visibility
RoundedRectangle(cornerRadius: 8)
    .stroke(increaseContrast ? Color(.label) : Color(.separator), lineWidth: increaseContrast ? 2 : 1)

// UIKit
UIAccessibility.isDarkerSystemColorsEnabled

NotificationCenter.default.addObserver(
    forName: UIAccessibility.darkerSystemColorsStatusDidChangeNotification,
    object: nil, queue: .main
) { _ in self.updateContrast() }
```

### Dark Interface — Dark Mode

```swift
// SwiftUI — support system Dark Mode
// Use semantic colors — they adapt automatically (see above)

// Detect current color scheme
@Environment(\.colorScheme) var colorScheme

// Force dark for testing
ContentView().environment(\.colorScheme, .dark)

// UIKit — respond to trait changes
// Pre-iOS 17:
override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) { // Deprecated in iOS 17
    super.traitCollectionDidChange(previousTraitCollection)
    if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
        updateColors()
    }
}

// iOS 17+ replacement:
registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
    self.updateColors()
}
```

### Critical: Test Dark + Increase Contrast Together

The most common failure is correct contrast in light mode but broken in dark mode. Always test both.

```swift
// Simulator test: Settings → Developer → Dark Appearance
// AND: Settings → Accessibility → Display & Text Size → Increase Contrast
//
// Use Accessibility Inspector
// (Xcode → Open Developer Tool → Accessibility Inspector → Settings tab)
// to simulate Increase Contrast on the Simulator.
#Preview("Dark Mode") {
    MyView()
        .environment(\.colorScheme, .dark)
}
```

**Common dark mode pitfalls:**
- Gray text on dark background (low contrast even for normal vision)
- Semi-transparent overlays that don't meet contrast in dark
- Images with white backgrounds that invert poorly
- Borders and dividers that disappear in dark mode

### Nutrition Label Criteria

To indicate **Sufficient Contrast**: All common task UI meets 4.5:1 for text, 3:1 for non-text, in BOTH light and dark mode, with Increase Contrast and Bold Text enabled.

To indicate **Dark Interface**: App is dark by default OR supports system Dark Mode, with no bright flashes and consistent dark appearance across all views.

---

## Differentiate Without Color

Up to 10% of people have some form of color vision deficiency. Color must never be the **only** indicator of meaning.

### Testing Method

Enable Grayscale color filter: Settings → Accessibility → Display & Text Size → Color Filters → Grayscale.
If any information becomes ambiguous or invisible in grayscale, the app fails this test.

### Detection

```swift
// SwiftUI
@Environment(\.accessibilityDifferentiateWithoutColor) var differentiateWithoutColor

// UIKit
UIAccessibility.shouldDifferentiateWithoutColor

NotificationCenter.default.addObserver(
    forName: UIAccessibility.differentiateWithoutColorDidChangeNotification,
    object: nil, queue: .main
) { _ in self.updateForColorAccessibility() }
```

### Patterns

**Status Indicators**

```swift
// ❌ Color only — fails grayscale
Circle().fill(isOnline ? .green : .red)

// ✅ Color + shape
Group {
    if isOnline {
        Circle().fill(.green)               // green circle
    } else {
        Circle()
            .fill(.red)
            .overlay(
                Image(systemName: "xmark")
                    .foregroundStyle(.white)
                    .font(.caption2)
            )
    }
}
// VoiceOver still needs a label:
.accessibilityLabel(isOnline ? "Online" : "Offline")
```

**Charts and Data Visualization**

```swift
// ❌ Color only — bars indistinguishable in grayscale
BarMark(x: .value("Month", month), y: .value("Sales", sales))
    .foregroundStyle(by: .value("Category", category))

// ✅ Color + pattern or symbol
BarMark(...)
    .foregroundStyle(by: .value("Category", category))
    .symbol(by: .value("Category", category))  // different symbols per category

// ✅ Or annotate directly on chart elements
```

**Conditional Enhancement**

```swift
@Environment(\.accessibilityDifferentiateWithoutColor) var differentiate

// Normally color-coded, enhanced with icons when setting is on
HStack {
    if differentiate {
        Image(systemName: status.iconName)
    }
    Text(status.label)
}
.foregroundStyle(status.color)
```

### Nutrition Label Criteria

To indicate **Differentiate Without Color**:
- App passes the Grayscale filter test (all information comprehensible)
- Status indicators use shape/icon/text in addition to color
- Charts/graphs use patterns, labels, or symbols in addition to color

---

## Reduce Transparency

```swift
// SwiftUI
@Environment(\.accessibilityReduceTransparency) var reduceTransparency

// UIKit
UIAccessibility.isReduceTransparencyEnabled

NotificationCenter.default.addObserver(
    forName: UIAccessibility.reduceTransparencyStatusDidChangeNotification,
    object: nil, queue: .main
) { _ in self.updateBlurEffects() }
```

### Replace Blur/Glass with Solid Backgrounds

```swift
// SwiftUI — conditional material
.background {
    if reduceTransparency {
        Color(.secondarySystemBackground)     // solid
    } else {
        Rectangle().fill(.ultraThinMaterial)  // blur
    }
}

// iOS 26 Liquid Glass [VERIFY] iOS 26 beta — API subject to change
if #available(iOS 26, *) {
    content.glassEffect(
        reduceTransparency ? .clear : .regular
    )
}

// UIKit
blurView.isHidden = UIAccessibility.isReduceTransparencyEnabled
solidBackground.isHidden = !UIAccessibility.isReduceTransparencyEnabled
```

---

## Bold Text

When Bold Text is enabled, system fonts render heavier. Custom fonts may need to respond.

```swift
// SwiftUI
@Environment(\.legibilityWeight) var legibilityWeight
let boldTextEnabled = (legibilityWeight == .bold)

Text("Important")
    .fontWeight(boldTextEnabled ? .heavy : .medium)

// UIKit
UIAccessibility.isBoldTextEnabled

// System fonts respond automatically when using preferredFont()
// Custom fonts may need manual weight adjustment:
NotificationCenter.default.addObserver(
    forName: UIAccessibility.boldTextStatusDidChangeNotification,
    object: nil, queue: .main
) { _ in self.updateFontWeights() }
```

---

## Smart Invert / Invert Colors

Smart Invert intelligently inverts most UI colors but should leave images, video, and app-specific content untouched.

### Opt Out Specific Views

```swift
// SwiftUI — protect images, video thumbnails, maps, charts
AsyncImage(url: photoURL) { image in
    image.resizable()
}
.accessibilityIgnoresInvertColors()

// UIKit
imageView.accessibilityIgnoresInvertColors = true
mapView.accessibilityIgnoresInvertColors = true
```

### What to Protect

- Photos and user-generated images
- Video thumbnails and players
- Maps and satellite imagery
- App icons displayed within content
- Charts with color-coded data (the color meaning would be inverted)

### What NOT to Protect

- UI chrome (buttons, backgrounds, navigation bars) — should invert
- Text and icons — should invert
- Custom-drawn backgrounds — should invert

---

## UIKit Notification Observation

Full list of accessibility status change notifications:

```swift
// Register all at once
let notifications: [(Notification.Name, Selector)] = [
    (UIAccessibility.reduceMotionStatusDidChangeNotification, #selector(motionChanged)),
    (UIAccessibility.darkerSystemColorsStatusDidChangeNotification, #selector(contrastChanged)),
    (UIAccessibility.reduceTransparencyStatusDidChangeNotification, #selector(transparencyChanged)),
    (UIAccessibility.boldTextStatusDidChangeNotification, #selector(boldTextChanged)),
    (UIAccessibility.differentiateWithoutColorDidChangeNotification, #selector(colorChanged)),
    (UIAccessibility.invertColorsStatusDidChangeNotification, #selector(invertChanged)),
    (UIAccessibility.voiceOverStatusDidChangeNotification, #selector(voiceOverChanged)),
    (UIAccessibility.switchControlStatusDidChangeNotification, #selector(switchControlChanged)),
    (UIAccessibility.assistiveTouchStatusDidChangeNotification, #selector(assistiveTouchChanged)),
]

notifications.forEach { name, selector in
    NotificationCenter.default.addObserver(self, selector: selector, name: name, object: nil)
}
```

---

## Common Failures

| Failure | Category | Fix |
|---|---|---|
| Animation plays with Reduce Motion on | Reduced Motion | Gate with `accessibilityReduceMotion` |
| Decorative animation not removed | Reduced Motion | Remove entirely for decorative; replace for functional |
| Low contrast gray text in dark mode | Dark Interface / Contrast | Use `.secondary` color, test with dark + Increase Contrast |
| Color-only status dots | Differentiate Without Color | Add icon or shape |
| Blur effect used with Reduce Transparency | Reduce Transparency | Replace with opaque fallback |
| Photo inverts with Smart Invert | Invert Colors | Add `.accessibilityIgnoresInvertColors()` |
| Custom color doesn't adapt to dark mode | Dark Interface | Use `UIColor` dynamic provider or Color Set asset |
| Hardcoded WCAG values not checked | Sufficient Contrast | Use Accessibility Inspector contrast checker |
| Bold Text ignored for custom fonts | Bold Text | Listen for notification, update weight |
| Auto-carousel doesn't stop | Reduced Motion | Stop autoplay when `accessibilityReduceMotion` is true |
