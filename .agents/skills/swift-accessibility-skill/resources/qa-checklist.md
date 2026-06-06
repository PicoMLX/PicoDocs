# Accessibility QA Checklist

Standalone checklist for manual accessibility testing. Hand this to QA testers — no skill or Claude knowledge required.

Aligned with Apple's 9 App Store Accessibility Nutrition Labels and WCAG 2.2 Level AA.

---

## How to Use This Checklist

1. Test on a **real device** — Simulator doesn't fully support VoiceOver, Voice Control, or Switch Control
2. Test **every key user flow**: launch, onboarding, login, main feature, settings, purchase (if applicable)
3. Mark each item: Pass / Fail / N/A
4. A single Fail in a Nutrition Label category means that label **cannot be claimed** on the App Store

---

## Before You Start: Xcode Tools

### Xcode Canvas Variants (during development)
In the preview canvas, click the **Variants** button (grid icon) at the bottom:
- **Dynamic Type Variants** — renders the view at all 12 text sizes
- **Color Scheme Variants** — shows light and dark mode side by side
- **Orientation Variants** — portrait and landscape

### Xcode Canvas Device Settings (during development)
Click the **Device Settings** button (slider icon) at the bottom of the canvas:
- Set color scheme, Dynamic Type size, and orientation for a single preview
- Combine settings to test specific scenarios (e.g., dark mode + large text)

### Accessibility Inspector (Simulator or device)
Xcode menu → Open Developer Tool → Accessibility Inspector
- **Inspection tab** — point at any element to see its label, traits, value, and frame size
- **Audit tab** — run automated checks on the current screen (missing labels, low contrast, small targets)
- **Settings tab** — toggle Increase Contrast, Reduce Motion, Bold Text, Reduce Transparency on the Simulator without changing device settings

### performAccessibilityAudit() (automated tests)
Add to XCUITest target (iOS 17+). Catches missing labels, low contrast, small hit regions, clipped text, and Dynamic Type failures in CI. See `resources/audit-template.swift` for a drop-in template.

---

## 1. VoiceOver

**Enable:** Settings → Accessibility → VoiceOver (or triple-click Side button if configured)

| # | Test | How to verify | Pass criteria |
|---|---|---|---|
| 1.1 | Navigate all elements | Swipe right repeatedly through entire screen | Every interactive element is reachable |
| 1.2 | Labels are meaningful | Tap each element, listen to announcement | Label describes the element concisely, not "button" or "image" |
| 1.3 | No redundant type in label | Listen for "button button" or "image image" | VoiceOver adds type automatically — label should not include it |
| 1.4 | State as traits | Toggle a switch, select a tab | VoiceOver says "selected" / "on" / "off" — not embedded in the label text |
| 1.5 | Decorative images hidden | Swipe through screen | Decorative images are skipped |
| 1.6 | Reading order is logical | Use "Read All" (two-finger swipe up) | Content reads in visual order, top-to-bottom, left-to-right |
| 1.7 | Focus after navigation | Push a new screen | Focus moves to first element of new screen (usually title or back button) |
| 1.8 | Focus after modal dismiss | Dismiss a sheet/alert | Focus returns to the element that triggered it |
| 1.9 | Adjustable controls work | Swipe up/down on slider or stepper | Value changes and is announced |
| 1.10 | Dynamic changes announced | Trigger a loading state or error | VoiceOver announces the change ("Loading complete", "Error: …") |
| 1.11 | Complete a key flow | Do the main task start-to-finish with VoiceOver | Task completes without sighted assistance |

---

## 2. Voice Control

**Enable:** Settings → Accessibility → Voice Control

| # | Test | How to verify | Pass criteria |
|---|---|---|---|
| 2.1 | Show numbers | Say "Show numbers" | Every interactive element has a number overlay |
| 2.2 | Tap by number | Say "Tap [number]" | Correct element activates |
| 2.3 | Show names | Say "Show names" | Every element shows its visible text label |
| 2.4 | Tap by name | Say "Tap [label]" | Element activates — label must match visible text exactly |
| 2.5 | Text input | Say "Type [text]" in a text field | Text is entered correctly |
| 2.6 | Scrolling | Say "Scroll down" / "Scroll up" | Content scrolls |
| 2.7 | Icon-only elements | Say "Tap Share" (or the label) for icon-only buttons | Button activates — requires `.accessibilityInputLabels` |

---

## 3. Larger Text (Dynamic Type)

**Enable:** Settings → Accessibility → Display & Text Size → Larger Text → drag slider to max

| # | Test | How to verify | Pass criteria |
|---|---|---|---|
| 3.1 | Text scales | Set to Accessibility 5 (max) | All text is larger |
| 3.2 | No clipping | Navigate all screens at max size | No text cut off without "..." affordance |
| 3.3 | No overlapping | Check all screens at max size | No elements overlap |
| 3.4 | Layout adapts | Check horizontal layouts | Rows/columns reflow to vertical when needed |
| 3.5 | Fixed UI chrome | Long-press on tab bar icons or toolbar items | Large Content Viewer shows enlarged version |
| 3.6 | Small text readable | Set to smallest size | Text is still readable |

**Quick check with Xcode:** Use Canvas Dynamic Type Variants to see all 12 sizes at once.

---

## 4. Sufficient Contrast

**Tool:** Accessibility Inspector → Inspection tab → Color contrast

| # | Test | How to verify | Pass criteria |
|---|---|---|---|
| 4.1 | Normal text | Check body text against background | ≥ 4.5:1 contrast ratio |
| 4.2 | Large text | Check headings (≥ 18pt or 14pt bold) | ≥ 3:1 contrast ratio |
| 4.3 | Non-text elements | Check icons, borders, focus rings | ≥ 3:1 contrast ratio |
| 4.4 | Both modes | Repeat all checks in Dark Mode | Passes in both light and dark |
| 4.5 | Increased Contrast | Enable Increase Contrast in Accessibility Inspector Settings | Borders and separators become more visible |
| 4.6 | Placeholder text | Check text field placeholders | ≥ 4.5:1 against background |

---

## 5. Dark Interface

**Enable:** Settings → Display & Brightness → Dark

| # | Test | How to verify | Pass criteria |
|---|---|---|---|
| 5.1 | All text readable | Navigate all screens | No white-on-white or invisible text |
| 5.2 | Borders visible | Check cards, sections, separators | Borders and dividers are visible |
| 5.3 | Images correct | Check photos, icons | No white halo; images aren't inverted incorrectly |
| 5.4 | Status indicators | Check colored status elements | Still distinguishable in dark mode |

---

## 6. Differentiate Without Color

**Enable:** Settings → Accessibility → Display & Text Size → Color Filters → Grayscale

| # | Test | How to verify | Pass criteria |
|---|---|---|---|
| 6.1 | Status indicators | Check error/success/warning states | Distinguishable by shape, icon, or text — not color alone |
| 6.2 | Charts and graphs | Check data visualizations | Data series distinguishable by pattern, shape, or label |
| 6.3 | Links | Check link text | Underlined or otherwise distinguishable from body text |
| 6.4 | Form validation | Trigger an error state | Error is indicated by icon or text, not just red color |

---

## 7. Reduced Motion

**Enable:** Settings → Accessibility → Motion → Reduce Motion

| # | Test | How to verify | Pass criteria |
|---|---|---|---|
| 7.1 | Navigation transitions | Push/pop screens | No sliding animation — dissolve or instant |
| 7.2 | UI animations | Trigger state changes, loading | Animations removed or replaced with fade/opacity |
| 7.3 | Auto-playing content | Check for auto-playing animations/video | Stopped or has manual play control |
| 7.4 | Parallax effects | Scroll content | No parallax or motion effects |

**Quick check:** Toggle Reduce Motion in Accessibility Inspector Settings tab while running in Simulator.

---

## 8. Captions

**Applies to:** Apps with video or audio content

| # | Test | How to verify | Pass criteria |
|---|---|---|---|
| 8.1 | Captions available | Play a video with dialogue | Captions can be enabled via player controls |
| 8.2 | Auto-enable | Enable Closed Captions in Settings → Accessibility → Subtitles & Captioning | Captions appear automatically |
| 8.3 | Captions accurate | Read captions while watching | Captions match spoken content |
| 8.4 | Timing correct | Watch captions during video | Captions sync with audio |

---

## 9. Audio Descriptions

**Applies to:** Apps with video content where visual information is important

| # | Test | How to verify | Pass criteria |
|---|---|---|---|
| 9.1 | Audio Descriptions available | Play a video | Audio Description track can be selected |
| 9.2 | Auto-enable | Enable Audio Descriptions in Settings → Accessibility → Audio Descriptions | Audio Descriptions play automatically |
| 9.3 | Content described | Listen to Audio Descriptions | Important visual information is narrated |

---

## 10. Additional Checks

### Switch Control

**Enable:** Settings → Accessibility → Switch Control

| # | Test | How to verify | Pass criteria |
|---|---|---|---|
| 10.1 | Scanning | Enable auto-scan | Every element is highlighted in sequence |
| 10.2 | Activation | Select a highlighted element | Correct action triggers |
| 10.3 | Custom actions | Navigate to elements with swipe actions | Actions appear in scanning menu |
| 10.4 | No timeouts | Use the app slowly | Nothing times out or auto-advances |

### Full Keyboard Access (iPad / Mac)

**Enable:** Settings → Accessibility → Keyboards → Full Keyboard Access

| # | Test | How to verify | Pass criteria |
|---|---|---|---|
| 10.5 | Tab navigation | Press Tab repeatedly | Focus moves through all interactive elements |
| 10.6 | Reverse Tab | Press Shift+Tab | Focus moves backward |
| 10.7 | Activation | Press Space or Return on focused element | Element activates |
| 10.8 | Escape dismissal | Press Escape on modal | Modal dismisses |
| 10.9 | No focus traps | Tab through entire app | Focus never gets stuck |

---

## Summary Template

After testing, fill in:

| Nutrition Label | Status | Blocking Issues |
|---|---|---|
| VoiceOver | Pass / Fail | |
| Voice Control | Pass / Fail | |
| Larger Text | Pass / Fail | |
| Sufficient Contrast | Pass / Fail | |
| Dark Interface | Pass / Fail | |
| Differentiate Without Color | Pass / Fail | |
| Reduced Motion | Pass / Fail | |
| Captions | Pass / Fail / N/A | |
| Audio Descriptions | Pass / Fail / N/A | |

### App Store recommendation draft

Use the completed summary above to prepare an App Store Accessibility Nutrition Label recommendation:

- You could claim: every label marked Pass
- You should not claim: every label marked Fail
- Not applicable: every label marked N/A
- Add short reasons for both supported and unsupported labels

Example handoff:

```md
Accessibility Nutrition Label recommendation

You could claim:
- VoiceOver
- Voice Control
- Larger Text
- Sufficient Contrast
- Dark Interface
- Differentiate Without Color
- Reduced Motion

Why you could claim them:
- VoiceOver: all reviewed common tasks are reachable, labeled, and operable with VoiceOver
- Voice Control: all reviewed interactive elements can be activated by visible name or input label
- Larger Text: reviewed screens reflow correctly and remain readable at the largest supported sizes
- Sufficient Contrast: reviewed text and interactive elements meet contrast requirements in light and dark mode
- Dark Interface: reviewed screens support dark appearance without unreadable content or broken chrome
- Differentiate Without Color: reviewed states and status indicators remain understandable without color alone
- Reduced Motion: reviewed transitions and state changes respect Reduce Motion

You should not claim:
- Captions
- Audio Descriptions

Why you should not claim them:
- Captions: the app has no primary video or long-form media experience in the reviewed scope
- Audio Descriptions: the app has no video content that would justify this label in the reviewed scope
```
