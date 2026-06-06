# ModelContext and Lifecycle

## Container Setup First

- Attach `.modelContainer(for: ...)` at app, scene, or top-level view.
- Or create `ModelContainer(...)` manually and inject it.
- If no container is attached, environment context is in-memory and schema-less:
  - inserts throw,
  - fetches return empty.

## Context Roles

- `container.mainContext` (or `@Environment(\.modelContext)`) is main-actor-bound and intended for UI-driven work.
- Custom `ModelContext(container)` is useful for controlled background or utility work.

## Autosave and Explicit Save

- `mainContext` is configured with autosave enabled by SwiftData.
- Manually created contexts are not implicitly configured the same way; set `autosaveEnabled` if needed.
- Use explicit `try context.save()` when operation boundaries must be deterministic.
- Use `transaction { ... }` for grouped mutations followed by save.

## Insert, Update, Delete

- Insert only graph roots; SwiftData traverses related models automatically.
- Updates are tracked automatically for known models; no explicit update API.
- `delete(_:)` removes specific instances.
- `delete(model:where:includeSubclasses:)` can remove many models at once.
  - Warning: no predicate means deleting all models of that type.

## Undo and Notifications

- Enable undo with `.modelContainer(..., isUndoEnabled: true)`.
- Automatic undo/redo support applies to changes saved through `mainContext`.
- Observe `ModelContext.willSave` and `ModelContext.didSave` for lifecycle hooks.
- Always scope notification subscriptions to a specific context object.

## Selection and Identity

- Use `persistentModelID` for stable selection identity in UI.
- Clear selection before deleting the selected object to avoid stale references.

## Safe Operational Pattern

```swift
@Environment(\.modelContext) private var context

func removeExpiredTrips() {
    do {
        try context.delete(model: Trip.self, where: #Predicate { $0.endDate < .now })
        try context.save()
    } catch {
        // Report and recover.
    }
}
```

## Primary Documentation

- https://developer.apple.com/documentation/swiftdata/modelcontainer
- https://developer.apple.com/documentation/swiftdata/modelcontext
- https://developer.apple.com/documentation/swiftdata/modelcontext/autosaveenabled
- https://developer.apple.com/documentation/swiftdata/modelcontext/delete(model:where:includesubclasses:)
- https://developer.apple.com/documentation/swiftdata/deleting-persistent-data-from-your-app
- https://developer.apple.com/documentation/swiftdata/reverting-data-changes-using-the-undo-manager
