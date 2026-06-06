# Concurrency and Actors

## Isolation Model

- Use `mainContext` for UI-bound operations.
- Use dedicated isolation for background persistence work.
- Avoid mixing long-running write flows directly in UI contexts.

## Model Actors

`@ModelActor` helps create actor-isolated persistence services with mutually exclusive access.

Benefits:

- serialized access to model operations,
- safer background processing,
- reduced accidental context sharing.

Pattern:

```swift
@ModelActor
actor TripStore {
    func saveTrip(_ trip: Trip) throws {
        modelContext.insert(trip)
        try modelContext.save()
    }
}
```

## Context Boundaries

- Do not pass mutable model instances loosely across isolation boundaries.
- Pass identifiers (`persistentModelID`) and refetch in the receiving context when needed.
- Keep context ownership explicit in service boundaries.

## Undo and Concurrency

- Automatic undo/redo integration is tied to main-context save flows.
- Background contexts are not a drop-in replacement for undo-enabled user editing.

## History with Concurrent Writers

- Set `modelContext.author` for different writers when useful.
- Filter fetched history by token and author to separate signal from noise.

## Primary Documentation

- https://developer.apple.com/documentation/swiftdata/concurrencysupport
- https://developer.apple.com/documentation/swiftdata/modelactor()
- https://developer.apple.com/documentation/swiftdata/modelactor
- https://developer.apple.com/documentation/swiftdata/modelexecutor
- https://developer.apple.com/documentation/swiftdata/defaultserialmodelexecutor
