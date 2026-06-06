# Querying and Fetching

## Choosing the API

- Use `@Query` in SwiftUI views for automatic refresh and simple binding to UI.
- Use `FetchDescriptor` + `modelContext.fetch(...)` outside views or for explicit control.
- Use `fetchCount(...)` when only count is needed.
- Use `fetchIdentifiers(...)` when only IDs are needed.

## Deterministic Query Design

- Centralize predicate construction in helper functions.
- Reuse the same predicate across related views (for example list + map) to prevent mismatch.
- Always define sort order explicitly for user-visible lists.
- Keep dynamic query parameters in the view initializer to force predictable query rebuilds.

## Dynamic Query Pattern

```swift
init(searchText: String, date: Date) {
    let predicate = Quake.predicate(searchText: searchText, searchDate: date)
    _quakes = Query(filter: predicate, sort: \.magnitude, order: .reverse)
}
```

## FetchDescriptor Controls

Configure `FetchDescriptor<T>` with:

- `predicate`: filter criteria.
- `sortBy`: one or more sort descriptors.
- `fetchLimit`: cap result size.
- `fetchOffset`: pagination offset.
- `includePendingChanges`: include unsaved changes in matching.
- `relationshipKeyPathsForPrefetching`: reduce relationship faulting overhead.
- `propertiesToFetch`: select only needed properties.

## Performance Guidance

- Combine indexing strategy with actual query keys.
- Avoid broad unbounded queries for high-cardinality models.
- Prefer count or identifier fetches for preliminary checks.
- Use explicit fetch limits for user-facing screens.
- Avoid repeated ad hoc filtering in `body`; encode filtering in query predicate.

## Common Failures

- `unsupportedPredicate` or `unsupportedSortDescriptor`: simplify predicate/sort to supported expressions.
- Inconsistent UI between views: shared predicate was not reused.
- Slow list rendering: missing indexes for frequently used sort/filter attributes.

## Primary Documentation

- https://developer.apple.com/documentation/swiftdata/query
- https://developer.apple.com/documentation/swiftdata/query()
- https://developer.apple.com/documentation/swiftdata/additionalquerymacros
- https://developer.apple.com/documentation/swiftdata/fetchdescriptor
- https://developer.apple.com/documentation/swiftdata/filtering-and-sorting-persistent-data
