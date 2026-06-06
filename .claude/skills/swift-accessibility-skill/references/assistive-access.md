# Assistive Access

Assistive Access is an iOS/iPadOS 17+ feature that provides a cognitively simplified system experience for people with intellectual disabilities. Apps can provide a dedicated, streamlined scene with large controls, visual alternatives, and reduced cognitive load.

## Contents
- [What Is Assistive Access](#what-is-assistive-access)
- [Info.plist Configuration](#infoplist-configuration)
- [SwiftUI Scene Setup](#swiftui-scene-setup)
- [UIKit Scene Setup](#uikit-scene-setup)
- [Runtime Detection](#runtime-detection)
- [Navigation Icons](#navigation-icons)
- [Design Principles](#design-principles)
- [Native Control Adaptation](#native-control-adaptation)
- [Testing](#testing)
- [Combining With Other Accessibility Features](#combining-with-other-accessibility-features)
- [Common Mistakes](#common-mistakes)

---

## What Is Assistive Access

Assistive Access replaces the standard iOS UI with a simplified launcher and app experience. Key characteristics:
- Large, clear controls with generous spacing
- Grid or row layout for app icons
- Streamlined navigation (no app switcher, no Control Center swipes)
- Visual alternatives to text throughout
- Reduced distractions and fewer options
- Aimed at caregivers and users with cognitive disabilities configuring a device together

When your app is declared as supporting Assistive Access, it appears in the **Optimized Apps** list in Settings, and launches using your dedicated scene when the user taps its icon.

---

## Info.plist Configuration

### Standard Support

Declares that your app supports Assistive Access. The system shows a separate scene (your `AssistiveAccess` scene) when launched in Assistive Access mode.

```xml
<key>UISupportsAssistiveAccess</key>
<true/>
```

### Full Screen (Optional)

For apps already designed for cognitive accessibility (AAC apps, specialized tools). The app displays full-screen with its normal interface instead of a reduced frame.

```xml
<key>UISupportsFullScreenInAssistiveAccess</key>
<true/>
```

Use this key **only** when your standard app UI is already appropriate for Assistive Access users. It bypasses the separate scene mechanism.

---

## SwiftUI Scene Setup

Add a dedicated `AssistiveAccess` scene alongside your main `WindowGroup`. The system activates this scene automatically when the user launches the app in Assistive Access mode.

```swift
import SwiftUI

@main
struct MyApp: App {
    var body: some Scene {
        // Standard app interface
        WindowGroup {
            ContentView()
        }

        // Dedicated Assistive Access interface
        AssistiveAccess {
            AssistiveAccessContentView()
        }
    }
}
```

### Assistive Access Content View

Design for clarity, large targets, and essential functionality only:

```swift
struct AssistiveAccessContentView: View {
    var body: some View {
        NavigationStack {
            List {
                NavigationLink("Send Message") {
                    ComposeMessageView()
                }

                NavigationLink("Read Messages") {
                    InboxView()
                }

                NavigationLink("Contacts") {
                    ContactsView()
                }
                // ✅ Only the most essential features
                // ❌ Do not include settings, advanced filters, or secondary actions
            }
            .navigationTitle("Messages")
            .assistiveAccessNavigationIcon(systemImage: "message.fill")
        }
    }
}
```

---

## UIKit Scene Setup

For UIKit apps, combine `UIHostingSceneDelegate` with the SwiftUI `AssistiveAccess` scene.

### Scene Delegate

```swift
import UIKit
import SwiftUI

class AssistiveAccessSceneDelegate: UIHostingSceneDelegate {
    static var rootScene: some Scene {
        AssistiveAccess {
            AssistiveAccessContentView()
        }
    }
}
```

### AppDelegate Configuration

```swift
import UIKit

@main
class AppDelegate: UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let role = connectingSceneSession.role
        let config = UISceneConfiguration(name: nil, sessionRole: role)

        // Route Assistive Access sessions to the dedicated delegate
        if role == .windowAssistiveAccessApplication {
            config.delegateClass = AssistiveAccessSceneDelegate.self
        }

        return config
    }
}
```

---

## Runtime Detection

Detect Assistive Access programmatically to adapt behavior within shared components.

Assistive Access as a feature is available on iOS/iPadOS 17+, but the SwiftUI environment value `accessibilityAssistiveAccessEnabled` is available on iOS/iPadOS 18+.
For iOS/iPadOS 17, prefer a dedicated `AssistiveAccess` scene and avoid shared-view branching unless you provide your own fallback.

### SwiftUI

```swift
struct MessageRow: View {
    @Environment(\.accessibilityAssistiveAccessEnabled) private var assistiveAccessEnabled
    var message: Message

    var body: some View {
        HStack {
            // Show avatar image in Assistive Access (visual alternative to text)
            if assistiveAccessEnabled {
                ContactAvatar(contact: message.sender, size: 60)
            }
            VStack(alignment: .leading) {
                Text(message.sender.name)
                    .font(assistiveAccessEnabled ? .title2 : .headline)
                Text(message.preview)
                    .font(assistiveAccessEnabled ? .body : .callout)
                    .lineLimit(assistiveAccessEnabled ? 3 : 2)
            }
        }
        .padding(assistiveAccessEnabled ? 16 : 12)
    }
}
```

If you support iOS/iPadOS 17, gate that environment value:

```swift
struct MessageRow: View {
    var message: Message

    var body: some View {
        if #available(iOS 18, iPadOS 18, *) {
            MessageRowContent(message: message)
        } else {
            LegacyMessageRowContent(message: message)
        }
    }
}

@available(iOS 18, iPadOS 18, *)
private struct MessageRowContent: View {
    @Environment(\.accessibilityAssistiveAccessEnabled) private var assistiveAccessEnabled
    let message: Message

    var body: some View {
        HStack {
            if assistiveAccessEnabled {
                ContactAvatar(contact: message.sender, size: 60)
            }
            VStack(alignment: .leading) {
                Text(message.sender.name)
                    .font(assistiveAccessEnabled ? .title2 : .headline)
                Text(message.preview)
                    .font(assistiveAccessEnabled ? .body : .callout)
                    .lineLimit(assistiveAccessEnabled ? 3 : 2)
            }
        }
        .padding(assistiveAccessEnabled ? 16 : 12)
    }
}

private struct LegacyMessageRowContent: View {
    let message: Message

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(message.sender.name)
                    .font(.headline)
                Text(message.preview)
                    .font(.callout)
                    .lineLimit(2)
            }
        }
        .padding(12)
    }
}
```

### Use Sparingly

Prefer providing a fully separate `AssistiveAccess` scene instead of branching on `assistiveAccessEnabled` throughout shared views. Detection is best for shared components that need minor adaptations.

---

## Navigation Icons

Assistive Access uses a grid or row launcher with large icons. Add navigation icons to all navigable views:

```swift
// System SF Symbol
.assistiveAccessNavigationIcon(systemImage: "star.fill")

// Custom image from Assets
.assistiveAccessNavigationIcon(Image("my-feature-icon"))
```

Icons appear in the Assistive Access launcher grid. Use clear, recognizable symbols that convey meaning without text.

```swift
struct AssistiveAccessContentView: View {
    var body: some View {
        NavigationStack {
            List {
                NavigationLink("Messages") { MessagesView() }
                NavigationLink("Photos") { PhotosView() }
                NavigationLink("Music") { MusicView() }
            }
            .navigationTitle("My App")
            .assistiveAccessNavigationIcon(systemImage: "house.fill")  // top-level icon
        }
    }
}

struct MessagesView: View {
    var body: some View {
        // ...
        List { /* messages */ }
            .navigationTitle("Messages")
            .assistiveAccessNavigationIcon(systemImage: "message.fill")
    }
}
```

---

## Design Principles

### 1. Distill to Core Functionality

Include only 1–3 essential features. Remove settings, advanced options, filters, and anything a caregiver would configure, not the primary user.

```swift
// ❌ Too many options for Assistive Access
List {
    NavigationLink("Inbox") { InboxView() }
    NavigationLink("Sent") { SentView() }
    NavigationLink("Drafts") { DraftsView() }
    NavigationLink("Spam") { SpamView() }
    NavigationLink("Trash") { TrashView() }
    NavigationLink("Settings") { SettingsView() }
    NavigationLink("Manage Accounts") { AccountsView() }
}

// ✅ Essential only
List {
    NavigationLink("Read Messages") { InboxView() }
    NavigationLink("Send Message") { ComposeView() }
}
```

### 2. Large, Clear Controls

Every interactive element should be a minimum of 60×60pt (exceeds the standard 44pt minimum):

```swift
Button("Send") { send() }
    .font(.title2)
    .frame(maxWidth: .infinity)
    .padding(.vertical, 20)
    .background(Color.accentColor)
    .foregroundStyle(.white)
    .clipShape(RoundedRectangle(cornerRadius: 12))
```

### 3. Multiple Representations

Combine text + icons + color. Never rely on text alone:

```swift
// ✅ Text + icon
Label("New Message", systemImage: "square.and.pencil")
    .font(.title2)

// ✅ Contact with photo + name
HStack {
    ContactAvatar(contact: contact, size: 56)
    Text(contact.name).font(.title3)
}
```

### 4. Intuitive Navigation

- Clear back buttons on every screen
- Step-by-step flows (one decision per screen)
- No hidden gestures or swipe navigation
- Consistent button placement across screens

### 5. Safe Interactions

- Add confirmation dialogs for irreversible actions
- Remove dangerous actions from primary flow
- Provide undo or cancel for every action

```swift
// ✅ Confirmation for destructive action
Button("Delete Message", role: .destructive) {
    showDeleteConfirm = true
}
.confirmationDialog("Delete this message?", isPresented: $showDeleteConfirm) {
    Button("Delete", role: .destructive) { delete() }
    Button("Cancel", role: .cancel) { }
}
```

---

## Native Control Adaptation

When using standard SwiftUI controls inside an `AssistiveAccess` scene, they automatically adopt the Assistive Access visual style:

- Buttons appear larger with bolder text
- Lists use prominent row separators
- Navigation titles are more prominent
- The overall appearance matches Assistive Access system apps

**No additional styling code is required** for native controls. Custom views need explicit adaptation.

---

## Testing

### SwiftUI Preview

```swift
#Preview(traits: .assistiveAccess) {
    AssistiveAccessContentView()
}
```

### On Device

1. Enable Assistive Access: Settings → Accessibility → Assistive Access → Set Up Assistive Access
2. Verify your app appears in "Optimized Apps" (requires `UISupportsAssistiveAccess` in Info.plist)
3. Add your app to the Assistive Access home screen
4. Test all user flows within Assistive Access mode
5. Turn off Assistive Access: triple-click the side button → Enter Passcode

### Checklist

- [ ] App appears in "Optimized Apps" in Assistive Access setup
- [ ] All essential tasks completable without reading ability (icons + text or icons alone)
- [ ] All interactive targets ≥ 60pt
- [ ] No gestures required for primary tasks
- [ ] Confirmation required for destructive actions
- [ ] Navigation icons defined for all top-level destinations
- [ ] Primary flow completable without reaching a dead end

---

## Combining With Other Accessibility Features

Assistive Access is compatible with VoiceOver, Voice Control, and Switch Control. Users may have multiple features active simultaneously.

When designing the Assistive Access scene:
- Use semantic labels (`accessibilityLabel`) for all elements (VoiceOver compatibility)
- Ensure buttons are `Button` types or have `.button` trait (Voice Control visibility)
- Avoid time-limited interactions (Switch Control compatibility)
- Keep touch targets ≥ 44pt minimum (standard accessibility) — aim for 60pt+

---

## Common Mistakes

| Mistake | Fix |
|---|---|
| Same UI in `AssistiveAccess` scene as standard | Create a genuinely simplified interface with fewer features |
| Missing `UISupportsAssistiveAccess` key | Add to Info.plist — required to appear in Optimized Apps |
| Touch targets under 44pt in AA scene | Use minimum 60pt for Assistive Access; standard controls auto-adapt |
| Gestures required for primary tasks | Replace with explicit buttons |
| No navigation icon | Add `.assistiveAccessNavigationIcon(systemImage:)` |
| Branching `assistiveAccessEnabled` everywhere | Use a separate scene instead — cleaner and more maintainable |
| Destructive actions without confirmation | Wrap in `.confirmationDialog` |
| Text-only controls without icons | Add `Label` with image or accompanying `Image` |
