# WCAG 2.2 → iOS/SwiftUI/UIKit Mapping

Maps WCAG 2.2 Level A and AA success criteria to native platform APIs. Covers iOS, macOS, watchOS, tvOS, and visionOS. Based on WCAG 2.2 and WCAG2ICT (mobile application guidance).

**Scope:** Level A and AA only — these are the standard compliance targets. Level AAA criteria are noted where native frameworks provide support.

---

## 1. Perceivable

### 1.1 Text Alternatives

| SC | Level | Requirement | Platform API |
|---|---|---|---|
| 1.1.1 Non-text Content | A | Text alternative for non-text content | SwiftUI: `.accessibilityLabel(_:)`, `.accessibilityHidden(true)` for decorative; UIKit: `accessibilityLabel`, `isAccessibilityElement = false` |

### 1.2 Time-based Media

| SC | Level | Requirement | Platform API |
|---|---|---|---|
| 1.2.1 Audio-only / Video-only | A | Alternative for prerecorded media | Provide transcript; use `AVPlayerViewController` |
| 1.2.2 Captions (Prerecorded) | A | Captions for prerecorded audio in video | `AVPlayerViewController` (auto-enables captions); `AVMediaCharacteristic.legible` |
| 1.2.3 Audio Description or Alternative | A | Audio description for prerecorded video | `AVMediaCharacteristic.describesVideoForAccessibility` |
| 1.2.4 Captions (Live) | AA | Captions for live audio in video | App-provided live captions/transcriptions integrated into the streaming experience|
| 1.2.5 Audio Description (Prerecorded) | AA | Audio description for prerecorded video | `AVPlayerViewController` + audio description track |

### 1.3 Adaptable

| SC | Level | Requirement | Platform API |
|---|---|---|---|
| 1.3.1 Info and Relationships | A | Programmatic structure matches visual | SwiftUI: `.accessibilityElement(children:)`, `.accessibilityAddTraits(.isHeader)`, `Section`, `NavigationStack`; UIKit: `UIAccessibilityTraits`, `accessibilityContainerType` |
| 1.3.2 Meaningful Sequence | A | Correct reading order | SwiftUI: `.accessibilitySortPriority(_:)`, layout order; UIKit: `accessibilityElements` array order |
| 1.3.3 Sensory Characteristics | A | Don't rely solely on shape, size, position, or sound | Combine visual cues with text labels and accessibility labels |
| 1.3.4 Orientation | AA | Content works in portrait and landscape | Support both orientations via Auto Layout / SwiftUI adaptive layout; lock only when essential (e.g., camera) |
| 1.3.5 Identify Input Purpose | AA | Programmatic purpose for input fields | UIKit: `textContentType` (`.emailAddress`, `.password`, etc.); SwiftUI: `.textContentType(_:)`, `.keyboardType(_:)` |

### 1.4 Distinguishable

| SC | Level | Requirement | Platform API |
|---|---|---|---|
| 1.4.1 Use of Color | A | Color is not the only visual indicator | Add shape, icon, or text alongside color; check with `@Environment(\.accessibilityDifferentiateWithoutColor)` |
| 1.4.2 Audio Control | A | Mechanism to pause/stop/control audio | Standard playback controls; respect silent mode |
| 1.4.3 Contrast (Minimum) | AA | 4.5:1 text, 3:1 large text | Semantic colors: `Color(.label)`, `Color(.secondaryLabel)`; check with Accessibility Inspector contrast checker; respond to `@Environment(\.colorSchemeContrast)` |
| 1.4.4 Resize Text | AA | Text resizable to 200% without loss | SwiftUI: `.font(.body)` text styles, `@ScaledMetric`; UIKit: `UIFontMetrics`, `adjustsFontForContentSizeCategory = true`; test with Dynamic Type Variants in Canvas |
| 1.4.5 Images of Text | AA | Use real text, not images of text | Use `Text` views with styling instead of rendered text images |
| 1.4.10 Reflow | AA | Content reflows at narrow widths | SwiftUI: `ViewThatFits` (iOS 16+), adaptive stacks; UIKit: Auto Layout with proper constraints |
| 1.4.11 Non-text Contrast | AA | 3:1 for UI components and graphics | Borders, icons, focus indicators against their backgrounds; use Accessibility Inspector |
| 1.4.12 Text Spacing | AA | Support adjusted spacing | Use system text styles — they respect user settings automatically |
| 1.4.13 Content on Hover/Focus | AA | Dismissible, hoverable, persistent | Ensure `.popover()` / `.help()` content stays visible when pointer moves into it, is dismissible via Escape, and persists until dismissed; avoid custom hover-triggered UI that vanishes on pointer move |

---

## 2. Operable

### 2.1 Keyboard Accessible

| SC | Level | Requirement | Platform API |
|---|---|---|---|
| 2.1.1 Keyboard | A | All functionality via keyboard | Full Keyboard Access: every element reachable via Tab; SwiftUI: `.focusable()`, `FocusState`; UIKit: `canBecomeFocused`, `UIKeyCommand` |
| 2.1.2 No Keyboard Trap | A | Keyboard focus can always move away | Ensure Escape dismisses modals; SwiftUI: `.sheet()` handles this; UIKit: implement `accessibilityPerformEscape()` |
| 2.1.4 Character Key Shortcuts | A | Single-key shortcuts can be remapped/disabled | Avoid single-character key shortcuts; use modifier keys (Cmd+, Ctrl+) |

### 2.2 Enough Time

| SC | Level | Requirement | Platform API |
|---|---|---|---|
| 2.2.1 Timing Adjustable | A | Users can extend time limits | Provide timeout warnings and extensions; no auto-advancing without user control |
| 2.2.2 Pause, Stop, Hide | A | Auto-updating content can be paused | Provide pause controls; respect `@Environment(\.accessibilityReduceMotion)` |

### 2.3 Seizures and Physical Reactions

| SC | Level | Requirement | Platform API |
|---|---|---|---|
| 2.3.1 Three Flashes | A | No content flashes > 3 times/second | Avoid flashing content; gate with `accessibilityReduceMotion` |

### 2.4 Navigable

| SC | Level | Requirement | Platform API |
|---|---|---|---|
| 2.4.1 Bypass Blocks | A | Skip repeated content | SwiftUI: use `NavigationStack`, `TabView` for structure; UIKit: `accessibilityContainerType = .semanticGroup` |
| 2.4.2 Page Titled | A | Screens have descriptive titles | SwiftUI: `.navigationTitle(_:)`; UIKit: `title` property on `UIViewController` |
| 2.4.3 Focus Order | A | Logical focus/navigation order | SwiftUI: `.accessibilitySortPriority(_:)`, layout order; UIKit: `accessibilityElements` array |
| 2.4.4 Link Purpose | A | Purpose of links clear from context | Use descriptive button/link labels; avoid "Click here" |
| 2.4.5 Multiple Ways | AA | Multiple ways to reach content | Tab bar + search + navigation hierarchy |
| 2.4.6 Headings and Labels | AA | Descriptive headings and labels | SwiftUI: `.accessibilityAddTraits(.isHeader)`; UIKit: `UIAccessibilityTraits.header` |
| 2.4.7 Focus Visible | AA | Keyboard focus indicator visible | System provides default focus rings; do not suppress them with `.focusEffectDisabled(true)`; AppKit: only set `NSView.focusRingType = .none` when drawing a custom focus ring or when space is insufficient for the default ring |
| 2.4.11 Focus Not Obscured (Minimum) | AA | Focused element not fully hidden | Ensure modals/overlays don't cover the focused element; use `.accessibilityViewIsModal` |

### 2.5 Input Modalities

| SC | Level | Requirement | Platform API |
|---|---|---|---|
| 2.5.1 Pointer Gestures | A | Single-pointer alternative to multi-touch | Provide button alternatives for pinch/rotate gestures; `.accessibilityAction` for custom gestures |
| 2.5.2 Pointer Cancellation | A | Down-event doesn't trigger action | Use `touchUpInside` (UIKit default), not `touchDown`; SwiftUI `Button` handles this automatically |
| 2.5.3 Label in Name | A | Accessible name contains visible text | Voice Control: `.accessibilityInputLabels` must match or contain visible text |
| 2.5.4 Motion Actuation | A | Alternative to device motion | Don't require shake/tilt; provide on-screen button alternative |
| 2.5.7 Dragging Movements | AA | Single-pointer alternative to drag | Provide button-based reorder; `.accessibilityAction(named: "Move Up") { … }`; `.accessibilityDragPoint` / `.accessibilityDropPoint` |
| 2.5.8 Target Size (Minimum) | AA | Touch targets ≥ 24×24 CSS px (44×44pt recommended) | SwiftUI: `.frame(minWidth: 44, minHeight: 44)`; UIKit: ensure `accessibilityFrame` ≥ 44×44pt; the Human Interface Guidelines recommend 44×44pt |

---

## 3. Understandable

### 3.1 Readable

| SC | Level | Requirement | Platform API |
|---|---|---|---|
| 3.1.1 Language of Page | A | Language of content is programmatic | Set app language in Info.plist `CFBundleDevelopmentRegion`; per-view: SwiftUI `.environment(\.locale, …)` |
| 3.1.2 Language of Parts | AA | Language of parts identified | `NSAttributedString` with `.accessibilitySpeechLanguage`; SwiftUI: `.accessibilitySpeechLanguage(_:)` |

### 3.2 Predictable

| SC | Level | Requirement | Platform API |
|---|---|---|---|
| 3.2.1 On Focus | A | No unexpected changes on focus | Don't trigger navigation or state changes on focus alone |
| 3.2.2 On Input | A | No unexpected changes on input | Confirm before submitting; don't auto-navigate on picker selection |
| 3.2.3 Consistent Navigation | AA | Consistent navigation across screens | Use standard `TabView`, `NavigationStack` patterns |
| 3.2.4 Consistent Identification | AA | Same function = same label | Use consistent `.accessibilityLabel` across screens for same action |
| 3.2.6 Consistent Help | A | Help mechanism in consistent location | Place help in Settings or consistent toolbar position |

### 3.3 Input Assistance

| SC | Level | Requirement | Platform API |
|---|---|---|---|
| 3.3.1 Error Identification | A | Errors identified and described | Post `AccessibilityNotification.Announcement` for errors; use `.accessibilityLabel` on error text |
| 3.3.2 Labels or Instructions | A | Input fields have labels | SwiftUI: `TextField("Email", …)`; UIKit: `accessibilityLabel` on `UITextField` |
| 3.3.3 Error Suggestion | AA | Suggest corrections for errors | Provide actionable error messages; use `.textContentType` for autofill suggestions |
| 3.3.4 Error Prevention (Legal/Financial) | AA | Reversible, verified, or confirmed | Confirm destructive actions; provide undo; review before submit |
| 3.3.7 Redundant Entry | A | Don't re-ask for previously entered info | Use Keychain, AutoFill, and state management to avoid re-entry |
| 3.3.8 Accessible Authentication (Minimum) | AA | No cognitive function test for auth | Support passkeys, biometrics (`LAContext`), password managers; avoid CAPTCHAs |

---

## 4. Robust

### 4.1 Compatible

| SC | Level | Requirement | Platform API |
|---|---|---|---|
| 4.1.2 Name, Role, Value | A | All UI components have accessible name, role, value | SwiftUI: `.accessibilityLabel`, `.accessibilityValue`, `.accessibilityAddTraits`; UIKit: `accessibilityLabel`, `accessibilityTraits`, `accessibilityValue` |
| 4.1.3 Status Messages | AA | Status changes announced without focus | SwiftUI: `AccessibilityNotification.Announcement(_:).post()`; UIKit: `UIAccessibility.post(notification: .announcement, argument:)` |

---

## Quick Lookup: WCAG SC → Nutrition Label

| Nutrition Label | Primary WCAG SC |
|---|---|
| VoiceOver | 1.1.1, 1.3.1, 1.3.2, 2.4.3, 2.4.6, 4.1.2 |
| Voice Control | 2.5.3, 2.5.8, 2.1.1 |
| Larger Text | 1.4.4, 1.4.10, 1.4.12 |
| Dark Interface | 1.4.3, 1.4.11 |
| Differentiate Without Color | 1.4.1, 1.4.11 |
| Sufficient Contrast | 1.4.3, 1.4.11 |
| Reduced Motion | 2.2.2, 2.3.1 |
| Captions | 1.2.2, 1.2.4 |
| Audio Descriptions | 1.2.3, 1.2.5 |

---

## Mobile-Specific Notes (from WCAG2ICT)

- **Touch targets**: WCAG 2.5.8 specifies 24×24 CSS pixels minimum. Human Interface Guidelines recommend 44×44pt — use that stricter standard.
- **Orientation**: Support all orientations unless essential to the experience (1.3.4). Don't lock to portrait unless the feature requires it (e.g., camera viewfinder).
- **Text resize**: iOS Dynamic Type satisfies 1.4.4. Test at all sizes including Accessibility sizes — use Xcode Canvas Dynamic Type Variants.
- **Drag alternatives**: 2.5.7 requires single-pointer alternatives to drag. Provide button-based reordering, `.accessibilityAction(named:)`, or `.accessibilityDragPoint` / `.accessibilityDropPoint`.
- **Authentication**: 3.3.8 is new in WCAG 2.2. Support biometrics (`Face ID`, `Touch ID`), passkeys, and password autofill to avoid cognitive function tests.
