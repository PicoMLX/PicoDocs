# Relationships and Inheritance

## Relationship Strategy

- Use enums (`Codable`) for static, app-defined classifications.
- Use model-to-model relationships for dynamic data created by users or external systems.

## `@Relationship` Essentials

Key parameters:

- `deleteRule`: behavior on owner deletion (`nullify`, `cascade`, `deny`, `noAction`).
- `inverse`: inverse key path to maintain object graph consistency.
- `minimumModelCount` and `maximumModelCount`: optional cardinality constraints.
- `originalName`: migration mapping support for renamed relationships.

Default delete rule is `.nullify`.

Important detail:

- If a relationship property is optional, min/max enforcement applies only when the property is non-`nil`.

## Delete Rule Guidance

- Use `.cascade` when related data has no standalone value.
- Use `.nullify` when related data can outlive the parent.
- Use `.deny` when parent deletion must be blocked while dependents exist.
- Validate delete behavior with tests before release.

## Inheritance Guidance

Use inheritance when there is a strong IS-A model:

- `BusinessTrip` is a `Trip`.
- `PersonalTrip` is a `Trip`.

Avoid inheritance when:

- specialization is too minor and better represented by a field/enum;
- query model is purely shallow and would only target subclasses with duplicated parent fields.

Inheritance tends to fit mixed deep + shallow querying requirements.

## Querying Across Hierarchies

- Base-class query for broad search across shared fields.
- Type-filtered predicates for subtype-only views:
  - `#Predicate { $0 is BusinessTrip }`
  - `#Predicate { $0 is PersonalTrip }`

## Primary Documentation

- https://developer.apple.com/documentation/swiftdata/defining-data-relationships-with-enumerations-and-model-classes
- https://developer.apple.com/documentation/swiftdata/relationship(_:deleterule:minimummodelcount:maximummodelcount:originalname:inverse:hashmodifier:)
- https://developer.apple.com/documentation/swiftdata/schema/relationship/deleterule-swift.enum
- https://developer.apple.com/documentation/swiftdata/adopting-inheritance-in-swiftdata
