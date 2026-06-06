# Accessibility Nutrition Labels

All 9 App Store Accessibility Nutrition Labels with official evaluation criteria, required APIs, and implementation checklists.

## Contents
- [Overview](#overview)
- [1. VoiceOver](#1-voiceover)
- [2. Voice Control](#2-voice-control)
- [3. Larger Text](#3-larger-text)
- [4. Dark Interface](#4-dark-interface)
- [5. Differentiate Without Color](#5-differentiate-without-color)
- [6. Sufficient Contrast](#6-sufficient-contrast)
- [7. Reduced Motion](#7-reduced-motion)
- [8. Captions](#8-captions)
- [9. Audio Descriptions](#9-audio-descriptions)
- [Evaluation Matrix Template](#evaluation-matrix-template)
- [Accuracy and App Review](#accuracy-and-app-review)

---

## Overview

Accessibility Nutrition Labels appear on App Store product pages. Each label indicates that users can complete **all common tasks** in the app using that accessibility feature. Partial support does not qualify — if any primary task is blocked, the label cannot be claimed.

**"Common tasks" typically means:**
- App launch and onboarding
- Primary feature usage (the core reason users download the app)
- Login / account access
- Settings or preferences
- Key data entry or purchase flows (if applicable)

Labels are currently voluntary. The platform review process checks accuracy during app review. Inaccurate labels violate App Store Review Guideline 2.3.

**Native APIs first:** Most built-in SwiftUI and UIKit controls provide accessibility for free. Custom implementations require explicit work for every feature.

---

## 1. VoiceOver

**What it is:** Screen reader for blind and low-vision users. Reads UI aloud and enables navigation through gestures.

### Pass Criteria

- [ ] All interactive controls (buttons, links, text fields) have concise, accurate accessibility labels
- [ ] Labels do not include the control type ("button", "link") — VoiceOver adds it automatically
- [ ] Labels do not embed state ("selected", "checked") — use traits for state
- [ ] Decorative images are hidden (`accessibilityHidden(true)`)
- [ ] All visible text is speakable by VoiceOver
- [ ] Reading order is logical and consistent with visual layout
- [ ] Element type and state are announced correctly (traits match element role)
- [ ] Navigation is complete — no interactive element is unreachable
- [ ] No unexpected VoiceOver cursor resets during content refresh
- [ ] All complex gestures (swipe, long-press, pinch) have accessible alternatives via custom actions
- [ ] Every modal and alert traps focus within itself (`accessibilityViewIsModal = true`)
- [ ] Every modal can be dismissed with the two-finger Z gesture (`accessibilityPerformEscape`)
- [ ] Focus moves to new content after navigation or modal presentation
- [ ] VoiceOver focus returns to the trigger element after modal dismissal
- [ ] Dynamic content changes (async loads, live regions) are announced

### Key APIs

| Feature | SwiftUI | UIKit |
|---|---|---|
| Label | `.accessibilityLabel(_:)` | `accessibilityLabel` |
| Hint | `.accessibilityHint(_:)` | `accessibilityHint` |
| Value | `.accessibilityValue(_:)` | `accessibilityValue` |
| Traits | `.accessibilityAddTraits(_:)` | `accessibilityTraits` |
| Hidden | `.accessibilityHidden(true)` | `isAccessibilityElement = false` |
| Custom actions | `.accessibilityAction(named:)` | `accessibilityCustomActions` |
| Modal trapping | Automatic with `.sheet()` | `accessibilityViewIsModal = true` |
| Focus | `@AccessibilityFocusState` | `UIAccessibility.post(.screenChanged)` |
| Announcements | `AccessibilityNotification.Announcement` | `UIAccessibility.post(.announcement)` |

---

## 2. Voice Control

**What it is:** Hands-free navigation by speaking commands. Used by people with motor disabilities who can see the screen.

### Pass Criteria

- [ ] Every interactive element appears in the "Show numbers" overlay
- [ ] Every element has a visible text label in the "Show names" overlay
- [ ] Labels in "Show names" match the text visible in the UI
- [ ] No generic labels ("button", "image") without specific context
- [ ] "Tap [visible text]" activates every labeled button
- [ ] Icon-only buttons have `accessibilityInputLabels` matching their action
- [ ] Custom actions appear as ">>" in the "Show numbers" overlay and are activatable
- [ ] "Type [text]" inserts text in every text field
- [ ] "Select [word]" selects text in text fields
- [ ] "Scroll up/down/left/right" works in scrollable content
- [ ] No Voice Control action requires a custom multi-touch gesture without a voice alternative

### Key APIs

| Feature | SwiftUI | UIKit |
|---|---|---|
| Input labels | `.accessibilityInputLabels([_:])` | `accessibilityUserInputLabels` |
| Make interactive | Use `Button` (preferred) | `isAccessibilityElement = true` + `.button` trait |
| Custom actions | `.accessibilityAction(named:)` | `accessibilityCustomActions` |
| Unique labels | `.accessibilityLabel("Delete \(item.name)")` | `accessibilityLabel` with context |

### Common Failures

- `onTapGesture` on non-Button views — element invisible to Voice Control
- `accessibilityLabel` says "Submit" but button text is "Send" — "Tap Send" fails
- Swipe-to-delete has no voice alternative — inaccessible to Voice Control users

---

## 3. Larger Text

**What it is:** Dynamic Type support — text and layout scale when the user increases their preferred font size.

### Pass Criteria

- [ ] All text uses Dynamic Type text styles (not fixed font sizes)
- [ ] Text scales at least to the largest Accessibility size (200% on iOS, 140% on watchOS)
- [ ] No text clips, overlaps, or truncates severely at Accessibility 5 size
- [ ] Layout adapts at large sizes (e.g., HStack switches to VStack)
- [ ] Non-text elements that must scale use `@ScaledMetric`
- [ ] Icon-only elements that cannot scale use `.accessibilityShowsLargeContentViewer()`
- [ ] Custom fonts use `Font.custom(_:size:relativeTo:)` or `UIFontMetrics`
- [ ] Full content is accessible — detail views or "More" affordances exist for truncated text

### Text Style Reference

| Style | Default Size | Use For |
|---|---|---|
| `.largeTitle` | 34pt | Screen titles |
| `.title` | 28pt | Primary headings |
| `.title2` | 22pt | Secondary headings |
| `.title3` | 20pt | Tertiary headings |
| `.headline` | 17pt bold | Section labels |
| `.body` | 17pt | Primary content |
| `.callout` | 16pt | Supporting content |
| `.subheadline` | 15pt | Secondary content |
| `.footnote` | 13pt | Footnotes |
| `.caption` | 12pt | Captions |
| `.caption2` | 11pt | Fine print |

### Key APIs

| Feature | SwiftUI | UIKit |
|---|---|---|
| Text styles | `.font(.body)`, `.font(.title2)` etc. | `UIFont.preferredFont(forTextStyle:)` |
| Custom fonts | `Font.custom(_:size:relativeTo:)` | `UIFontMetrics.default.scaledValue(for:)` |
| Scale non-font values | `@ScaledMetric(relativeTo: .body)` | `UIFontMetrics(forTextStyle:).scaledValue(for:)` |
| Large Content Viewer | `.accessibilityShowsLargeContentViewer()` | `UILargeContentViewerInteraction` |
| Detect size | `@Environment(\.dynamicTypeSize)` | `traitCollection.preferredContentSizeCategory` |

---

## 4. Dark Interface

**What it is:** App supports system Dark Mode, or the app is dark by default.

### Pass Criteria

- [ ] App responds to system Dark Mode (appearance changes without relaunch) OR app is dark by default
- [ ] All text has sufficient contrast in dark mode (test with Increase Contrast enabled)
- [ ] No bright flashes during view transitions
- [ ] Consistent dark appearance across all views (no screens that stay light)
- [ ] Semantic colors used throughout (not hardcoded hex values)
- [ ] Custom colors have dark mode variants (Color Set or UIColor dynamic provider)
- [ ] Images with white backgrounds use `accessibilityIgnoresInvertColors` if needed
- [ ] Borders and dividers remain visible in dark mode

### Key APIs

| Feature | SwiftUI | UIKit |
|---|---|---|
| Detect mode | `@Environment(\.colorScheme)` | `traitCollection.userInterfaceStyle` |
| Semantic colors | `.foregroundStyle(.primary)`, `Color(.systemBackground)` | `.label`, `.systemBackground` |
| Dynamic color | Asset catalog Color Set | `UIColor { traits in traits.userInterfaceStyle == .dark ? ... : ... }` |
| Respond to changes | Automatic with semantic colors | `traitCollectionDidChange(_:)` (deprecated iOS 17; use `registerForTraitChanges`) |
| Force dark for testing | `.environment(\.colorScheme, .dark)` | `overrideUserInterfaceStyle = .dark` |

### Common Pitfalls

- Sufficient contrast in light mode but broken in dark mode — **always test both**
- Gray text on dark background — use `.secondary` which adjusts automatically
- Semi-transparent overlays that pass contrast in light but fail in dark

---

## 5. Differentiate Without Color

**What it is:** Color is not the only indicator of meaning. Required for users with color vision deficiency (affects ~10% of people).

### Pass Criteria

- [ ] App passes the Grayscale filter test (all information comprehensible in grayscale)
- [ ] Status indicators use shape, icon, or text in addition to color
- [ ] Charts and data visualizations use patterns, labels, or position in addition to color
- [ ] Interactive state (selected, disabled) is communicated beyond color
- [ ] Error and success states are distinguishable without color
- [ ] Links are distinguishable from non-interactive text (underline or weight, not color alone)
- [ ] `accessibilityDifferentiateWithoutColor` setting is respected when extra indicators are added

### Key APIs

| Feature | SwiftUI | UIKit |
|---|---|---|
| Detect setting | `@Environment(\.accessibilityDifferentiateWithoutColor)` | `UIAccessibility.shouldDifferentiateWithoutColor` |
| Observe changes | `.onChange(of: differentiateWithoutColor)` | `UIAccessibility.differentiateWithoutColorDidChangeNotification` |
| Chart symbols | `.symbol(by: .value(...))` on Swift Charts | Per-series symbol shapes |

### Test Method

Enable: Settings → Accessibility → Display & Text Size → Color Filters → Grayscale. Navigate every screen. If any information becomes ambiguous or invisible, the test fails.

---

## 6. Sufficient Contrast

**What it is:** Text and interactive elements meet WCAG contrast ratios for users with low vision.

### WCAG Contrast Ratios

| Element | Minimum | Enhanced (AAA) |
|---|---|---|
| Normal text (<18pt regular, <14pt bold) | **4.5:1** | 7:1 |
| Large text (≥18pt regular or ≥14pt bold) | **3:1** | 4.5:1 |
| Non-text interactive elements | **3:1** | — |
| State indicators (checkbox border, toggle track) | **3:1** | — |
| Decorative text with no informational value | None required | — |
| Placeholder text | **4.5:1** (must be readable) | — |

### Pass Criteria

- [ ] All body text meets 4.5:1 in both light and dark mode
- [ ] Large text meets 3:1 in both light and dark mode
- [ ] All interactive element borders, focus indicators, and state markers meet 3:1
- [ ] Placeholder text meets 4.5:1 (visible but distinct from entered text)
- [ ] Test passes with Bold Text AND Increase Contrast both enabled
- [ ] Contrast verified with Accessibility Inspector contrast checker or equivalent tool

### Key APIs

```swift
// SwiftUI — semantic colors automatically adapt contrast
@Environment(\.colorSchemeContrast) var contrast
let increaseContrast = (contrast == .increased)

// Example: use thicker borders when contrast is increased
RoundedRectangle(cornerRadius: 8)
    .stroke(
        increaseContrast ? Color(.label) : Color(.separator),
        lineWidth: increaseContrast ? 2 : 1
    )

// UIKit
UIAccessibility.isDarkerSystemColorsEnabled
```

---

## 7. Reduced Motion

**What it is:** Users who experience vestibular disorders disable motion to avoid nausea and dizziness.

### Pass Criteria

- [ ] Parallax effects, depth simulation, and animated blur are disabled
- [ ] Spinning, vortex, or multi-axis animations are removed or replaced
- [ ] Auto-advancing carousels and slideshows stop or provide manual control
- [ ] Meaningful animations (those that convey information) are replaced — not removed — with dissolve/fade/color shift
- [ ] Purely decorative animations are removed entirely
- [ ] System setting is detected automatically (no in-app setting required to pass)

### Decision Rule

**Decorative animation** (bouncing logo, particle effect, background ripple): **Remove entirely.**

**Functional animation** (card slides to show it's saved, view zooms to show hierarchy): **Replace** with a motion-free equivalent (fade, color change, highlight). Never remove — removing breaks comprehension.

### Key APIs

| Feature | SwiftUI | UIKit | watchOS |
|---|---|---|---|
| Detect | `@Environment(\.accessibilityReduceMotion)` | `UIAccessibility.isReduceMotionEnabled` | `WKAccessibilityIsReduceMotionEnabled()` |
| Observe | `onChange(of: reduceMotion)` | `UIAccessibility.reduceMotionStatusDidChangeNotification` | `WKAccessibilityReduceMotionStatusDidChange` |

---

## 8. Captions

**What it is:** Subtitles and captions for video and audio content, for deaf and hard-of-hearing users.

### Pass Criteria

- [ ] Captions are enabled automatically when the system "Closed Captions + SDH" setting is on
- [ ] All dialogue in first-party video is captioned
- [ ] Sound effects relevant to understanding are captioned (SDH format)
- [ ] Captions for third-party content show a CC or SDH badge indicator
- [ ] Text transcripts available for audio-only content
- [ ] Caption appearance follows system preferences (size, color, font)
- [ ] Do not claim if the app has no video or audio content

### Key APIs

| Feature | API |
|---|---|
| Auto caption support | Use `AVPlayerViewController` — handles everything automatically |
| Check system setting | `MACaptionAppearanceGetDisplayType(.user)` |
| Select caption track | `AVMediaSelectionGroup` with `.legible` characteristic |
| SDH characteristic | `AVMediaCharacteristic.isSDH` |
| Custom player | Select track when `MACaptionAppearanceGetDisplayType` returns `.alwaysOn` |

---

## 9. Audio Descriptions

**What it is:** Narration of visual content in video for blind users.

### Pass Criteria

- [ ] Audio Descriptions track activates automatically when system AD setting is on
- [ ] All first-party video visual actions, scene changes, and on-screen text are described
- [ ] Game interstitials and cut scenes are covered
- [ ] Third-party content with AD shows an "AD" badge indicator
- [ ] Do not claim support if very little described content is available
- [ ] Do not claim if the app has no video content

### Key APIs

| Feature | API |
|---|---|
| Auto AD support | Use `AVPlayerViewController` — selects AD track automatically |
| Detect AD track | `AVMediaSelectionGroup` with `.describesVideoForAccessibility` characteristic |
| Show "AD" badge | Check track exists → display badge in custom player UI |
| Audio session | `.spokenAudio` mode with `.duckOthers` to coexist with other audio |

---

## Evaluation Matrix Template

Use this table before submitting a Nutrition Label. Mark each common task as Pass (✅), Fail (❌), or Not Applicable (—).

| Common Task | VoiceOver | Voice Control | Larger Text | Dark Mode | No Color | Contrast | Motion | Captions | Audio Desc |
|---|---|---|---|---|---|---|---|---|---|
| App launch / onboarding | | | | | | | | | |
| Login / authentication | | | | | | | | | |
| Core primary feature | | | | | | | | | |
| Search / browse content | | | | | | | | | |
| Settings / preferences | | | | | | | | | |
| Purchase / transaction | | | | | | | | | |
| Media playback | | | | | | | | — |

**All cells in a column must be ✅ or — to claim that Nutrition Label.**

---

## Accuracy and App Review

The platform review process validates Nutrition Label claims during app review. Inaccurate declarations violate **App Store Review Guideline 2.3**.

- Incomplete support (e.g., VoiceOver works for browsing but not checkout) → do not claim
- Partial compliance (e.g., captions for some videos but not all) → do not claim
- Test on a real device, not only in Simulator or Previews
- Re-evaluate after every major release that touches UI or media
