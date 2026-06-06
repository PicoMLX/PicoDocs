# Modeling and Schema

## Core Rules

- Annotate persistable classes with `@Model`.
- Treat model code as the schema source of truth.
- Expect noncomputed stored properties to persist by default when types are supported.
- Use primitive types and `Codable` value types for persisted attributes.
- Remember computed properties are effectively transient.

## Attribute Design

Use `@Attribute(...)` to override default behavior when needed:

- `.unique`: enforce uniqueness for a single attribute.
- `.preserveValueOnDeletion`: keep selected values in history tombstones after delete.
- `.spotlight`, `.allowsCloudEncryption`, `.externalStorage`: use only when product requirements justify them.
- `originalName`: map renamed properties for migration continuity.
- `hashModifier`: advanced schema hashing override for migration scenarios.

Prefer explicit annotations only where behavior differs from defaults.

## Unique and Index Macros (iOS 18+)

For iOS 18+ targets, prefer freestanding macros at model scope:

- `#Unique<Model>([\.id], [\.name, \.date])` for single or compound uniqueness constraints.
- `#Index<Model>([\.date], [\.status, \.date])` for query-oriented binary indexes.
- `#Index<Model>(...)` with typed index variants for advanced indexing modes.

Notes:

- `#Unique` supports to-one relationship attributes, not arrays of related models.
- Keep index definitions aligned with real query predicates and sort keys.

## Relationships as Schema

- Use `@Relationship(...)` when data is dynamic and belongs to another model.
- Use enums (`Codable`) when related data is static and app-defined.
- Set `inverse` explicitly when clarity matters.
- Treat delete rules as domain rules, not implementation details.

## Transient Data

Use `@Transient` for runtime-only state that must not be stored.

- For nonoptional transient properties, provide a default value.
- Keep network/loading/UI flags transient.

## Schema Availability and Planning

- Base SwiftData model macros are available from iOS 17.
- `#Unique` and `#Index` are available from iOS 18.
- Inheritance support appears in newer updates and examples (check deployment targets before adopting in shared code paths).

## Example Pattern

```swift
@Model
final class Trip {
    #Unique<Trip>([\.externalID])
    #Index<Trip>([\.startDate], [\.destination, \.startDate])

    @Attribute(.unique) var externalID: String
    var destination: String
    var startDate: Date

    @Relationship(deleteRule: .cascade, inverse: \Activity.trip)
    var activities: [Activity] = []

    @Transient var isExpanded = false
}
```

## Primary Documentation

- https://developer.apple.com/documentation/swiftdata/model()
- https://developer.apple.com/documentation/swiftdata/attribute(_:originalname:hashmodifier:)
- https://developer.apple.com/documentation/swiftdata/unique(_:)
- https://developer.apple.com/documentation/swiftdata/index(_:)-74ia2
- https://developer.apple.com/documentation/swiftdata/index(_:)-7d4z0
- https://developer.apple.com/documentation/swiftdata/transient()
