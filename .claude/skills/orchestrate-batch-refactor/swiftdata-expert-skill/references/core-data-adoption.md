# Core Data Adoption

## Adoption Paths

Use one of three migration patterns:

1. Full conversion from Core Data to SwiftData.
2. Incremental migration by feature/module.
3. Coexistence (for example host app on Core Data, widget on SwiftData).

Choose based on release risk and integration constraints.

## Model Mapping Guidance

- Keep entity names, key attributes, and relationships aligned when migrating incrementally.
- Use `@Model` classes as the SwiftData model layer.
- Keep relationship and delete-rule semantics equivalent during migration.

## Coexistence Practices

When Core Data and SwiftData coexist:

- Use namespaced Core Data classes (`CDTrip`, etc.) to avoid class name collisions.
- Point both stacks to the same store URL when shared persistence is required.
- Enable persistent history tracking in the Core Data stack (`NSPersistentHistoryTrackingKey`) to match SwiftData expectations.

## Cross-Process Change Detection

For host app and widget workflows:

- Prefer consuming SwiftData persistent history over duplicate "unread" fields or side-channel storage.
- Track history token progress and process only relevant model updates.

## Migration Checklist

- Validate app group container and shared store path.
- Validate both stacks against same dataset.
- Validate deletes and relationship behavior across both stacks.
- Validate extension-driven updates in main app UI.
- Validate fallback behavior when history token expires.

## Primary Documentation

- https://developer.apple.com/documentation/coredata/adopting-swiftdata-for-a-core-data-app
- https://developer.apple.com/documentation/swiftdata/fetching-and-filtering-time-based-model-changes
