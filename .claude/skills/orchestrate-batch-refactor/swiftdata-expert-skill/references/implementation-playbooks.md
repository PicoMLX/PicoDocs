# Implementation Playbooks

## 1) Add a New Persisted Feature

1. Define or extend `@Model` classes.
2. Add relationship and delete-rule semantics explicitly where needed.
3. Add uniqueness and indexing strategy (if deployment target supports it).
4. Wire UI fetches through `@Query` or `FetchDescriptor`.
5. Validate CRUD and list behavior on realistic data volume.
6. Validate delete and rollback behavior.

Deliverables:

- model changes,
- query changes,
- migration impact statement.

## 2) Prepare a Schema Upgrade Release

1. Diff current and next schema in model code.
2. Classify changes as lightweight or custom migration candidates.
3. Introduce `VersionedSchema` and `SchemaMigrationPlan` when needed.
4. Rehearse migration on existing store snapshots.
5. Verify backward compatibility assumptions and failure behavior.

Deliverables:

- migration stage plan,
- rehearsal results,
- rollback and recovery notes.

## 3) Debug CloudKit Sync Divergence

1. Verify capabilities and remote notifications.
2. Confirm SwiftData container selection (`automatic`, explicit private, or `.none`).
3. Check schema compatibility constraints.
4. Validate writes on source device and reads on destination device.
5. Inspect history and context save flows for missed writes.

Deliverables:

- root-cause summary,
- config changes,
- validation evidence from at least two devices/simulators.

## 4) Handle Cross-Process Updates (Widget/Intent/App Extension)

1. Set context authoring strategy.
2. Fetch history using token + predicate.
3. Filter relevant changes by model type and changed attributes.
4. Update UI state and persist newest token.
5. Delete stale history safely after all consumers process it.

Deliverables:

- token persistence path,
- history filtering logic,
- cleanup policy.

## 5) Improve Query Performance

1. Identify slow user-visible queries.
2. Align predicates and sort descriptors with indexes.
3. Add fetch limits, offsets, or identifier-only fetches.
4. Eliminate duplicate filtering logic in view code.
5. Compare behavior before and after changes on large datasets.

Deliverables:

- before/after query strategy,
- measured or observed UX impact,
- remaining risks.

## Primary Documentation

- https://developer.apple.com/documentation/swiftdata/preserving-your-apps-model-data-across-launches
- https://developer.apple.com/documentation/swiftdata/filtering-and-sorting-persistent-data
- https://developer.apple.com/documentation/swiftdata/schemamigrationplan
- https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices
- https://developer.apple.com/documentation/swiftdata/fetching-and-filtering-time-based-model-changes
