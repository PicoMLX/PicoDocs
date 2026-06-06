# Migrations and History

## Schema Evolution Strategy

1. Start with automatic (lightweight) migration expectations.
2. If changes exceed lightweight capabilities, define `SchemaMigrationPlan`.
3. Model versions explicitly with `VersionedSchema`.
4. Use `MigrationStage.lightweight(...)` or `MigrationStage.custom(...)` between versions.

Use `originalName` and, when needed, `hashModifier` to preserve continuity for renamed properties.

## Migration Plan Skeleton

```swift
enum AppMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self, SchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self)]
    }
}
```

## Persistent History Usage

Use history when you need cross-process or temporal change tracking (widgets, intents, extensions, background writers).

- Fetch by token and/or author with `HistoryDescriptor`.
- Store latest token after successful processing.
- Filter transaction changes to only relevant model types and attributes.
- Delete stale transactions to reclaim disk.

## Deletion Tombstones

If deleted models must remain externally identifiable:

- mark key fields with `@Attribute(.preserveValueOnDeletion)`,
- read preserved values from delete change tombstones.

## Operational Risks

- `historyTokenExpired` means requested history was already deleted.
- Rebuild token baseline after cleanup or retention-window changes.
- Ensure cleanup strategy does not delete history before all consumers process it.

## Release Notes to Track

- 2024 updates: `#Unique`, `#Index`, history APIs, custom data store protocols.
- 2025 updates: inheritance support and history sorting improvements.

## Primary Documentation

- https://developer.apple.com/documentation/swiftdata/schemamigrationplan
- https://developer.apple.com/documentation/swiftdata/versionedschema
- https://developer.apple.com/documentation/swiftdata/migrationstage
- https://developer.apple.com/documentation/swiftdata/fetching-and-filtering-time-based-model-changes
- https://developer.apple.com/documentation/swiftdata/historydescriptor
- https://developer.apple.com/documentation/updates/swiftdata
