# CloudKit Sync

## Required Capabilities

SwiftData automatic sync requires:

- iCloud capability with CloudKit container,
- Background Modes with Remote notifications.

Without both, automatic server-driven updates are incomplete.

## Compatibility Constraints

CloudKit support is not universal across all SwiftData features.

- Review schema compatibility before enabling sync.
- Unique constraints and nonoptional relationships are documented limitations to account for.
- Plan schema carefully before production promotion.

Important production rule:

- CloudKit production schemas are additive-only after promotion.

## Container Selection

Default behavior:

- SwiftData reads entitlements and uses the first discovered container.

Explicit selection:

```swift
let config = ModelConfiguration(
    cloudKitDatabase: .private("iCloud.com.example.MyApp")
)
```

Disable automatic SwiftData sync:

```swift
let config = ModelConfiguration(cloudKitDatabase: .none)
```

Use `.none` for apps that already use CloudKit with incompatible schema assumptions.

## Development Schema Initialization

For initialization workflows in development:

1. Build store description from SwiftData store URL.
2. Configure `NSPersistentCloudKitContainerOptions`.
3. Load store synchronously.
4. Initialize CloudKit schema.
5. Unload store before constructing SwiftData `ModelContainer`.

Run this workflow only in debug/nonproduction code paths.

## Verification Checklist

- CloudKit container visible and correct in Apple Developer configuration.
- Device receives background remote notifications.
- Development schema initialized and inspected in CloudKit Dashboard.
- Multi-device write/read scenarios validated before production rollout.

## Primary Documentation

- https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices
- https://developer.apple.com/documentation/swiftdata/modelconfiguration
- https://developer.apple.com/documentation/swiftdata/modelcontainer
