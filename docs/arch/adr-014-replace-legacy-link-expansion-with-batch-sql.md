# Decision Record: Replace legacy link expansion with batch SQL queries

## Context

Publishing API has two implementations of link expansion:

1. **Legacy link expansion** (`lib/link_expansion.rb`, `app/models/link_graph/`) - used at publish time to pre-compute expanded links for Content Store
2. **GraphQL link expansion** (`app/graphql/sources/`) - used at request time to compute expanded links on demand

Both produce the same output (verified by integration tests in `spec/integration/graphql/link_expansion/`), but the legacy implementation is significantly less efficient.

### How legacy link expansion works

Legacy link expansion is a depth-first traversal:

1. **Build a `LinkGraph`**: Starting from a root edition, recursively discover linked content_ids by querying `Queries::Links.from()` and `Queries::Links.to()` once per node. Each query returns content_ids grouped by link_type, plus `has_own_links` / `is_linked_to` EXISTS flags to prune unnecessary recursion.

2. **Load edition content via `ContentCache`**: Once the full graph is built, batch-load all edition data using `Queries::GetEditionIdsWithFallbacks` (locale/state fallback) and `ExpansionRules::POSSIBLE_FIELDS_FOR_LINK_EXPANSION`.

3. **Populate links**: Walk the graph again, applying `ExpansionRules.expand_fields()` to filter each edition to the fields appropriate for its link_type and document_type.

The key problem is step 1: building the `LinkGraph` requires **one SQL query per node** in the graph. For content with many link types and multi-level paths, this can mean 10-50+ queries per expansion.

### How GraphQL link expansion works

The GraphQL implementation uses two SQL queries (in `app/graphql/sources/queries/`):

- **`linked_to_editions.sql`** - "Given these (edition_id, content_id, link_type) tuples, return the target editions." Handles both edition links and link_set links (with edition links taking precedence via `NOT EXISTS`), locale fallback (`DISTINCT ON` + `ORDER BY is_primary_locale`), and state priority (`ORDER BY CASE state`).

- **`reverse_linked_to_editions.sql`** - "Given these (content_id, link_type) tuples, return editions that link TO these content_ids." Same deduplication and fallback logic.

Both queries accept **batch inputs** via `json_to_recordset()`, so a single query handles all link types for all editions at a given depth level. The GraphQL `Dataloader` framework collects all pending requests at one depth level and issues them as a single batch - effectively a breadth-first traversal with **O(depth) queries instead of O(nodes)**.

### Dependency resolution

[Dependency resolution](../dependency-resolution.md) is "link expansion in reverse" - when content changes, it finds all other content that includes the changed item in its expanded links, so those items can be re-presented to Content Store.

Dependency resolution currently uses the **same `LinkGraph`** as link expansion, but with a different `LinkReference` implementation (`DependencyResolution::LinkReference`) that reverses the traversal direction:

| Aspect | Link Expansion | Dependency Resolution |
|--------|---------------|----------------------|
| Root level | `Links.from()` (own links) + `Links.to()` (reverse links) | `Links.to()` (direct deps) + `Links.from()` (reverse deps) |
| Child levels | direct then reverse | reverse then direct |
| Path rules | `ExpansionRules::LinkExpansion` (forward `MULTI_LEVEL_LINK_PATHS`) | `ExpansionRules::DependencyResolution` (backward `MULTI_LEVEL_LINK_PATHS`) |
| Output | Nested hash with expanded edition fields | Flat list of content_ids |

The reversal is controlled by `ExpansionRules::MultiLevelLinks` which accepts a `backwards: true` flag to process `MULTI_LEVEL_LINK_PATHS` in reverse order.

## Decision

Replace the legacy link expansion and dependency resolution graph traversal with a breadth-first approach using the SQL queries from the GraphQL implementation.

### What changes

**New class: breadth-first link expander** (replaces `LinkExpansion`, `DependencyResolution`, and the `LinkGraph` model)

The expander works as follows:

1. **Level 0 (root)**: Determine all valid link types for the root edition. Execute `linked_to_editions.sql` for direct link types and `reverse_linked_to_editions.sql` for reverse link types. This is one query per direction.

2. **Level 1+**: For each edition found at the previous level, compute the valid next link types using `ExpansionRules::LinkExpansion.allowed_direct_link_types(path)` / `allowed_reverse_link_types(path)`. Batch all editions at this level into one query per direction. Maintain a visited set of content_ids to prevent cycles.

3. **Termination**: Stop when no more valid paths exist in `MULTI_LEVEL_LINK_PATHS` or when queries return no new results.

4. **Field selection**: Apply `ExpansionRules.expand_fields()` to each edition to produce the final nested hash output.

For **dependency resolution**, the same BFS approach is used but with:
- Swapped query directions (reverse query first at root level)
- `ExpansionRules::DependencyResolution` for path validation instead of `ExpansionRules::LinkExpansion`
- Only content_ids collected, no field expansion needed

**Removed code:**

| File/Directory | Reason |
|---|---|
| `app/models/link_graph.rb` | Replaced by BFS with visited set |
| `app/models/link_graph/node.rb` | No longer needed |
| `app/models/link_graph/node_collection_factory.rb` | No longer needed |
| `lib/link_expansion/link_reference.rb` | Replaced by direct SQL query calls |
| `lib/link_expansion/content_cache.rb` | SQL queries return full editions directly |
| `lib/link_expansion/edition_hash.rb` | Replaced by direct edition field extraction |
| `lib/dependency_resolution/link_reference.rb` | Replaced by reversed BFS |
| `app/queries/links.rb` | Subsumed by the two SQL queries |
| `app/queries/edition_links.rb` | Subsumed by the two SQL queries |

**Retained code:**

| File/Directory | Reason |
|---|---|
| `lib/expansion_rules.rb` | Still needed for path validation and field selection |
| `lib/expansion_rules/link_expansion.rb` | Still needed for forward path validation |
| `lib/expansion_rules/dependency_resolution.rb` | Still needed for backward path validation |
| `lib/expansion_rules/multi_level_links.rb` | Still needed for path computation |
| `lib/link_expansion/edition_diff.rb` | Still needed for change tracking in commands |
| `app/queries/content_dependencies.rb` | Wraps dependency resolution with locale handling; stays as-is |
| `app/sidekiq/dependency_resolution_job.rb` | Orchestration stays the same, just calls new code |

**Unchanged code (callers):**

The downstream jobs (`DownstreamDraftJob`, `DownstreamLiveJob`), commands (`PutContent`, `Publish`, `PatchLinkSet`), and presenters (`EditionPresenter`, `Presenters::Queries::ExpandedLinkSet`) continue to call `LinkExpansion.by_edition()` / `LinkExpansion.by_content_id()` and `DependencyResolution#dependencies` - only the internal implementation changes.

### Implementation details

#### Edition links at nested levels

Legacy link expansion only follows edition links at the root level. At child levels, `child_links_by_link_type` only calls `Queries::Links` (link_set links), not `Queries::EditionLinks`.

The `linked_to_editions.sql` query handles both edition links (via `edition_linked_editions` CTE) and link_set links (via `link_set_linked_editions` CTE). To preserve current behavior at child levels, pass `edition_id: NULL` in the query input for non-root nodes. The `edition_linked_editions` CTE joins on `source_editions.id = query_input.edition_id`, so NULL produces no matches - only link_set links are returned. No SQL changes needed.

#### The `auto_reverse_link` behavior

When the root edition has a reverse link at level 1 (e.g., `children`), legacy link expansion embeds the root edition back into the reverse-linked item's nested links (see `LinkExpansion#auto_reverse_link`). For example, if B links to A via `parent`, then A's expanded links include `children: [{ ...B, links: { parent: [A] } }]`.

This is a post-processing step independent of graph traversal. After the BFS completes, iterate over level-1 reverse links and inject the root edition as a nested direct link.

#### Cycle prevention

Legacy code tracks `parent_content_ids` and excludes them via `WHERE NOT IN` in `Queries::Links`. The BFS approach uses a visited set instead. Cycles are rare in practice, so filtering in Ruby after query results return is sufficient and avoids complicating the SQL.

#### Extracting SQL queries from GraphQL sources

The SQL queries currently live in `app/graphql/sources/queries/` and are loaded by `LinkedToEditionsSource` and `ReverseLinkedToEditionsSource`. These should be extracted to a shared location (e.g., `app/queries/sql/`) so they can be used by both GraphQL dataloaders and the new BFS expander. The GraphQL sources would change only their `File.read` path.

The query execution logic currently in the GraphQL source classes (building `query_input` JSON, setting `sql_params`, calling `Edition.find_by_sql`) should be extracted into a shared query class that both the GraphQL sources and the BFS expander call.

#### Batch input construction

At each BFS level, construct the `query_input` JSON array from all nodes at that level:

- For forward links: `[{ edition_id: (id or NULL), content_id: ..., link_type: ... }, ...]` for each (node, allowed_link_type) pair
- For reverse links: `[{ content_id: ..., link_type: ... }, ...]` for each (node, allowed_reverse_link_type) pair

Group results back by `(source_content_id, link_type)` or `(target_content_id, link_type)` to rebuild the tree structure.

### Test coverage assessment

The existing integration tests are at the right abstraction level for this refactoring - they test through the public interfaces (`LinkExpansion.by_content_id` / `.by_edition`, `DependencyResolution#dependencies`) that will be preserved:

| Test file | What it exercises |
|-----------|-------------------|
| `spec/integration/link_expansion_spec.rb` (639 lines) | Non-renderable editions, draft state handling, recursive graphs (parent chains, taxon hierarchies), cyclic dependencies, multiple link types, locale fallback, withdrawn items, auto_reverse_link embedding, edition links across locales, stale local data |
| `spec/lib/link_expansion_spec.rb` (90 lines) | Withdrawn links by link_type (parent vs related vs related_statistical_data_sets), recursive expansion, locale fallback, draft-only fields (auth_bypass_ids) |
| `spec/integration/edition_links_spec.rb` (231 lines) | Edition vs link_set precedence (same type = edition wins), state combinations (draft/published/superseded source × target), locale matching, reverse links with edition links, edition links don't recurse at nested levels |
| `spec/integration/dependency_resolution_spec.rb` (286 lines) | Direct deps, recursive vs non-recursive link types, cycles, multi-level path chains (ordered_related_items → mainstream_browse_pages → parent, both valid and invalid paths), reverse links (child_taxons), edition links, draft/locale filtering, role appointments |
| `spec/queries/content_dependencies_spec.rb` (283 lines) | Translation dependencies, draft translation filtering, multi-locale linkers, parent graph chains, reverse link types, content_store filtering |
| `spec/integration/graphql/link_expansion/` (6 files) | Parity between `Presenters::Queries::ExpandedLinkSet` and GraphQL dataloaders for inclusion/exclusion and precedence of both direct and reverse links |

Unit tests for classes we're deleting (`spec/queries/links_spec.rb`, `spec/queries/edition_links_spec.rb`, `spec/models/link_graph_spec.rb`, `spec/lib/link_expansion/link_reference_spec.rb`, `spec/lib/dependency_resolution/link_reference_spec.rb`) will be removed along with the code they test.

**One gap to fill before starting**: link ordering tiebreaking. The behavior that links are ordered by `position ASC, link_id DESC` (i.e. when two links share the same position, the one with the higher link_id comes first) is currently only tested in `spec/queries/links_spec.rb`, which we're deleting. An integration-level test for equal-position tiebreaking should be added to `spec/integration/link_expansion_spec.rb` before beginning the refactor.

### Implementation plan

0. Add integration-level test for link ordering tiebreaking (equal positions, verify link_id DESC order)
1. Extract the SQL queries and query execution logic from the GraphQL sources into shared query classes
2. Build the new BFS link expander class with the same public interface as `LinkExpansion`
3. Build the new BFS dependency resolver with the same public interface as `DependencyResolution`
4. Run both old and new implementations in parallel (dual-write or shadow mode) and compare outputs to verify parity
5. Switch callers to the new implementation
6. Remove the old code (`LinkGraph`, `ContentCache`, `LinkReference` classes, `Queries::Links`, `Queries::EditionLinks`)
7. Update documentation (`docs/link-expansion.md`, `docs/dependency-resolution.md`)

## Consequences

### Fewer database queries per expansion

The current approach executes O(nodes) queries to build the link graph. The new approach executes O(depth) queries, where depth is typically 2-3 levels. For content with many link types (e.g., 10+ link types at the root level), this reduces the query count from ~20-50 to ~4-6.

### Simpler code

The `LinkGraph` / `Node` / `NodeCollectionFactory` / `LinkReference` / `ContentCache` abstraction layers are replaced by a straightforward BFS loop. The `has_own_links` / `is_linked_to` EXISTS optimization in `Queries::Links` (which added significant SQL complexity) becomes unnecessary - in a BFS model, a "wasted" query for a level that returns no results costs almost nothing because it's batched with everything else at that level.

### Single source of truth for link queries

The SQL queries are currently maintained in two places: `Queries::Links` / `Queries::EditionLinks` (for legacy) and `app/graphql/sources/queries/` (for GraphQL). After this change, only the SQL query files remain, used by both GraphQL and publish-time expansion.

### Edition links at nested levels

Legacy link expansion does not follow edition links at nested levels (only link_set links). The GraphQL implementation follows both. This ADR preserves the legacy behavior by passing `edition_id: NULL` for child nodes, but this could be revisited in future - following edition links at all levels is arguably more correct and would remove the need for link_set links for recursive expansion (as noted in the [link expansion docs](../link-expansion.md#put-content---edition-links)).

### Dependency resolution continues to work

Dependency resolution maps cleanly onto the BFS approach because it uses the same two primitive operations (forward links, reverse links) with the direction swapped. The `ExpansionRules::DependencyResolution` class already handles backward path validation, and this code is retained unchanged.

### Risk: subtle behavioral differences

The main risk is subtle differences in ordering or deduplication between the old per-node queries and the new batch queries. Mitigations:

- The GraphQL integration tests (`spec/integration/graphql/link_expansion/`) already verify parity between GraphQL and legacy expansion
- The implementation plan includes a parallel-running phase to compare outputs before switching over
- The SQL queries handle ordering deterministically (`link_type ASC, position ASC, link_id DESC`) and deduplication explicitly (`DISTINCT ON`)

### Dependency resolution no longer needs the link graph

`DependencyResolution` currently uses a `LinkGraph` (meaning dependency resolution works the same as link expansion, just with a different `LinkReference`). After this change, dependency resolution uses a simpler BFS that only collects content_ids. The `DependencyResolution#link_graph` method (used for debugging in the rails console, as documented in `docs/dependency-resolution.md`) will no longer exist and should be replaced with equivalent debugging tooling.

## Amendment: deviations discovered during implementation

Two things in the plan above turned out not to hold once the work was done, and
the implementation deviates accordingly:

- **`Queries::Links` and `Queries::EditionLinks` are retained**, not removed
  (contradicting "Implementation plan" step 6 and "Single source of truth for
  link queries"). Dependency resolution must return a dependent's `content_id`
  even when that content has no renderable edition, but the shared batch SQL
  `INNER JOIN`s `editions`. So `DependencyResolution::BreadthFirstResolver`
  reads the `links` table directly: the root reuses `Queries::Links` /
  `Queries::EditionLinks`, and the recursive levels batch plain `links`-table
  reads (link set links only, matching legacy). It therefore does **not** share
  the two batch SQL files with link expansion ("Dependency resolution continues
  to work" overstated the overlap).

- **A `link_source` discriminator column was added to both batch SQL files.**
  The expander needs to know whether each edition was reached via an edition
  link to reproduce two legacy behaviours: not expanding the children of a node
  reached via an edition link, and excluding edition-sourced reverse links at
  child levels. The column is additive and ignored by the GraphQL dataloaders.

The `LinkExpansion::EditionHash` class is also retained (used by
`lib/graphql/auto_reverse_linker.rb` and the new expander), and parity was
verified via the existing integration + GraphQL suites rather than a
parallel-running shadow-compare phase.
