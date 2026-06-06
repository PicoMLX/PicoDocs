# Dynamic Type and Larger Text

Dynamic Type lets users choose their preferred text size system-wide. Apps must support it to qualify for the **Larger Text** Accessibility Nutrition Label.

## Contents
- [Text Style Reference](#text-style-reference)
- [SwiftUI Implementation](#swiftui-implementation)
- [@ScaledMetric](#scaledmetric)
- [Large Content Viewer](#large-content-viewer)
- [Adaptive Layout Patterns](#adaptive-layout-patterns)
- [UIKit Implementation](#uikit-implementation)
- [Testing](#testing)
- [Common Failures](#common-failures)

---

## Text Style Reference

Always use text styles — never hardcode font sizes. Text styles scale automatically with the user's preferred size.

| Style | Default Size | Use Case |
|---|---|---|
| `.largeTitle` | 34pt | Main screen titles |
| `.title` | 28pt | Section titles |
| `.title2` | 22pt | Subsection titles |
| `.title3` | 20pt | Card or group titles |
| `.headline` | 17pt (semibold) | Table row headers, important labels |
| `.subheadline` | 15pt | Supporting text next to headline |
| `.body` | 17pt | Primary reading text |
| `.callout` | 16pt | Annotations, asides |
| `.footnote` | 13pt | Fine print, timestamps |
| `.caption` | 12pt | Image captions, secondary labels |
| `.caption2` | 11pt | Smallest readable text |

---

## SwiftUI Implementation

### Standard Text Styles — Automatic Scaling

No extra work needed. SwiftUI scales these automatically.

```swift
// ✅ Scales with Dynamic Type
Text("Welcome back")
    .font(.title)

Text("Your recent orders")
    .font(.headline)

// ❌ Hardcoded — does NOT scale
Text("Welcome back")
    .font(.system(size: 28))
```

### Custom Fonts with Text Styles

```swift
// ✅ Custom font that scales with the body text style
Text("Note")
    .font(.custom("Merriweather-Regular", size: 17, relativeTo: .body))

// ❌ Custom font with fixed size
Text("Note")
    .font(.custom("Merriweather-Regular", size: 17))
```

### Reading Dynamic Type Size

```swift
@Environment(\.dynamicTypeSize) var dynamicTypeSize

var body: some View {
    if dynamicTypeSize >= .accessibility1 {
        // Large type layout
        VStack(alignment: .leading) {
            avatar
            nameAndDetails
        }
    } else {
        // Standard layout
        HStack {
            avatar
            nameAndDetails
        }
    }
}
```

### `DynamicTypeSize` Reference

```
.xSmall  .small  .medium  .large (default)  .xLarge  .xxLarge  .xxxLarge
.accessibility1  .accessibility2  .accessibility3  .accessibility4  .accessibility5
```

`.accessibility5` is the maximum size. Test your layout at this size.

### Limiting Dynamic Type Size

Only limit size when the layout genuinely cannot accommodate larger text. Always provide alternatives.

```swift
// Limit a compact thumbnail — Large Content Viewer compensates
ThumbnailView()
    .dynamicTypeSize(.xSmall ... .accessibility2)
    .accessibilityShowsLargeContentViewer()  // required when limiting!
```

---

## @ScaledMetric

`@ScaledMetric` scales ANY numeric value (spacing, icon size, corner radius) proportionally with the user's text size preference.

```swift
struct ProfileRow: View {
    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 44
    @ScaledMetric(relativeTo: .body) private var spacing: CGFloat = 12
    @ScaledMetric(relativeTo: .caption) private var badgeSize: CGFloat = 16

    var body: some View {
        HStack(spacing: spacing) {
            Avatar()
                .frame(width: avatarSize, height: avatarSize)
            VStack(alignment: .leading, spacing: spacing / 3) {
                nameLabel
                timestampLabel
            }
        }
    }
}
```

**`relativeTo:`** — specifies which text style the metric scales with. Use the same style as the adjacent text.

```swift
// Scales with body text
@ScaledMetric(relativeTo: .body) var iconSize: CGFloat = 24

// Scales with headline text
@ScaledMetric(relativeTo: .headline) var rowHeight: CGFloat = 44
```

---

## Large Content Viewer

The Large Content Viewer shows an enlarged version of UI elements that cannot scale with Dynamic Type — typically items in fixed-size containers like tab bars and toolbars. Users long-press to see the enlarged version.

### When to Use

Use when an element's size is intentionally constrained (for layout reasons) and cannot grow with Dynamic Type.

- Tab bar items
- Toolbar buttons
- Badge labels
- Navigation bar title when using custom small sizes

**Do NOT use as a replacement** for supporting Dynamic Type in regular content.

### SwiftUI

```swift
// Tab bar item — automatically handled by TabView
// For custom fixed-size elements:

Image(systemName: "bell.fill")
    .font(.system(size: 20))
    .frame(width: 44, height: 44)
    .dynamicTypeSize(.xSmall ... .accessibility2)  // size-constrained
    .accessibilityShowsLargeContentViewer()         // required!
    .accessibilityLabel("Notifications")

// Custom content in the viewer
Image(systemName: "bell.fill")
    .accessibilityShowsLargeContentViewer {
        Label("Notifications", systemImage: "bell.fill")
    }
```

### UIKit — `UILargeContentViewerInteraction`

```swift
class CustomTabBarItem: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupLargeContentViewer()
    }

    private func setupLargeContentViewer() {
        showsLargeContentViewer = true
        largeContentTitle = "Library"
        largeContentImage = UIImage(systemName: "books.vertical")

        let interaction = UILargeContentViewerInteraction()
        addInteraction(interaction)
    }
}
```

### Large Content Viewer Design Requirements

- Minimum element height: 28pt (system recommendation: 44pt)
- Short title (1–2 words max)
- Clear icon (SF Symbol or simple custom image)

---

## Adaptive Layout Patterns

At large text sizes, horizontal space becomes scarce. Common adaptations:

### HStack → VStack Switch

```swift
@Environment(\.dynamicTypeSize) var typeSize

var body: some View {
    Group {
        if typeSize >= .accessibility1 {
            VStack(alignment: .leading, spacing: 8) { content }
        } else {
            HStack(spacing: 12) { content }
        }
    }
}

// Or using ViewThatFits (iOS 16+) — automatically picks the layout that fits
ViewThatFits {
    HStack { content }   // tried first
    VStack { content }   // fallback if HStack doesn't fit
}
```

### Truncation Strategy

```swift
// ✅ Wrap text, don't truncate primary content
Text(longTitle)
    .fixedSize(horizontal: false, vertical: true)   // allows vertical expansion
    .lineLimit(nil)

// ✅ Truncate secondary content, keep primary readable
HStack {
    Text(primaryLabel)
        .lineLimit(2)
    Text(secondaryLabel)
        .lineLimit(1)
        .foregroundStyle(.secondary)
}

// ❌ Truncates the only label — VoiceOver still reads it, but Visual isn't accessible
Text(importantLabel)
    .lineLimit(1)
    .truncationMode(.tail)
```

### Avoiding Fixed Heights

```swift
// ❌ Clips text at large sizes
.frame(height: 44)

// ✅ Minimum height with uncapped growth
.frame(minHeight: 44)

// ✅ Or just let SwiftUI size it naturally
// (HStack/VStack children grow to fit their content)
```

---

## UIKit Implementation

### Text Styles — `UIFont.preferredFont`

```swift
// ✅ Scales with Dynamic Type
label.font = UIFont.preferredFont(forTextStyle: .body)
label.adjustsFontForContentSizeCategory = true  // required for updates

// ❌ Fixed size — doesn't scale
label.font = UIFont.systemFont(ofSize: 17)
```

`adjustsFontForContentSizeCategory = true` is essential — without it, the font is set once and never updates when the user changes their text size.

### Custom Fonts with `UIFontMetrics`

```swift
let customFont = UIFont(name: "Merriweather-Regular", size: 17)!
label.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: customFont)
label.adjustsFontForContentSizeCategory = true
```

### Scaling Non-Font Values

```swift
// Scale spacing, icon sizes, etc.
let baseSpacing: CGFloat = 8
let scaledSpacing = UIFontMetrics.default.scaledValue(for: baseSpacing)

// Scale relative to a specific text style
let bodyMetrics = UIFontMetrics(forTextStyle: .body)
let iconSize = bodyMetrics.scaledValue(for: 24)
```

### Reacting to Size Changes

```swift
// Pre-iOS 17:
override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) { // Deprecated in iOS 17
    super.traitCollectionDidChange(previousTraitCollection)

    if traitCollection.preferredContentSizeCategory != previousTraitCollection?.preferredContentSizeCategory {
        updateLayout()
    }
}

// iOS 17+ replacement:
registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
    self.updateLayout()
}

// Or observe the notification (works on all versions)
NotificationCenter.default.addObserver(
    self,
    selector: #selector(contentSizeCategoryDidChange),
    name: UIContentSizeCategory.didChangeNotification,
    object: nil
)
```

### `UIContentSizeCategory` Reference

```swift
// Progression from smallest to largest:
let categoriesInOrder: [UIContentSizeCategory] = [
    .extraSmall,
    .small,
    .medium,
    .large, // default
    .extraLarge,
    .extraExtraLarge,
    .extraExtraExtraLarge,
    .accessibilityMedium,
    .accessibilityLarge,
    .accessibilityExtraLarge,
    .accessibilityExtraExtraLarge,
    .accessibilityExtraExtraExtraLarge
]

// Check if accessibility size is active
let isAccessibilitySize = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
```

### SF Symbols Scaling with Text

```swift
// Scale symbol with adjacent body text
let config = UIImage.SymbolConfiguration(textStyle: .body)
imageView.image = UIImage(systemName: "star.fill", withConfiguration: config)

// Scale to specific point size
let sizedConfig = UIImage.SymbolConfiguration(pointSize: 24, weight: .medium)
imageView.image = UIImage(systemName: "heart.fill", withConfiguration: sizedConfig)?
    .applyingSymbolConfiguration(.preferringMulticolor()) // append configurations
```

---

## Testing

### Minimum Testing Requirements

| Size | Category | Setting |
|---|---|---|
| Small | `.small` | Settings → Display & Text Size |
| Default | `.large` | Default |
| Large | `.extraExtraLarge` | ~150% scaling |
| Maximum | `.accessibilityExtraExtraExtraLarge` | 200%+ |
| watchOS max | — | 140%+ |

### SwiftUI Preview Testing

```swift
// Test at specific sizes
#Preview("Large Accessibility Size") {
    ContentView()
        .environment(\.dynamicTypeSize, .accessibility5)
}

#Preview("Default Size") {
    ContentView()
        .environment(\.dynamicTypeSize, .large)
}
```

### Xcode Simulator

In Simulator: Hardware → Device Settings → Increase Contrast + Dynamic Text → drag to max.

Or in Accessibility Inspector (macOS): connect to Simulator and adjust font size.

---

## Common Failures

| Failure | Fix |
|---|---|
| `.font(.system(size: 17))` | Use `.font(.body)` |
| Fixed frame clips text | Use `.frame(minHeight: 44)` not `height: 44` |
| HStack overflows at large sizes | Switch to `VStack` or `ViewThatFits` |
| Custom font doesn't scale | Add `relativeTo:` to `.custom()` or use `UIFontMetrics` |
| `adjustsFontForContentSizeCategory` missing | Set to `true` on all labels |
| Icon size stays fixed | Use `@ScaledMetric` or `UIFontMetrics.scaledValue` |
| Large Content Viewer not shown for tab items | Add `.accessibilityShowsLargeContentViewer()` explicitly |
| Single-line truncation loses information | Use `.lineLimit(nil)` or provide detail view on tap |
| Language testing missing | Test German (long words), Arabic (RTL), Japanese (tall characters) |
