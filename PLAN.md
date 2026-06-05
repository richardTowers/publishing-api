# ADR-014: Replace legacy link expansion with batch-SQL BFS

## Context

Publishing API has **two** implementations of link expansion that produce the same
output:

1. **Legacy** (`lib/link_expansion.rb`, `app/models/link_graph/`, `lib/link_expansion/`,
   `app/queries/links.rb`, `app/queries/edition_links.rb`) — used at publish time to
   pre-compute expanded links for the Content Store. It is a depth-first traversal that
   builds a `LinkGraph` by issuing **one SQL query per node** (≈O(nodes): 20–50 queries
   for richly-linked content).
2. **GraphQL** (`app/graphql/sources/`) — used at request time. It uses two batch SQL
   queries (`linked_to_editions.sql`, `reverse_linked_to_editions.sql`) driven by the
   GraphQL `Dataloader`, giving an effectively breadth-first traversal of **O(depth)**
   queries (typically 4–6).

`docs/arch/adr-014-...md` decides to delete the legacy graph traversal and re-implement
both **link expansion** and **dependency resolution** ("link expansion in reverse") as a
breadth-first (BFS) expander built on the same two batch SQL queries the GraphQL API
already uses. Outcome: far fewer queries per expansion, a single source of truth for the
link SQL, and the removal of the `LinkGraph` / `Node` / `LinkReference` / `ContentCache`
abstraction layers.

The public interfaces are preserved; only the internals change. Verified callers:
`Presenters::Queries::ExpandedLinkSet` (→ `EditionPresenter`, `DownstreamDraftJob`,
`GetExpandedLinks`), and `Queries::ContentDependencies` (→ `DependencyResolutionJob`,
`HostContentUpdateJob`).

**Decisions taken for this plan (from the user):**
- **Parity verification: test/CI only.** No production/staging shadow-comparison wrapper.
  We rely on the existing integration + GraphQL-parity suites, run against the new
  implementation in CI, and a simple `legacy | new` toggle for incremental landing and
  rollback. (No dual-run/compare machinery.)
- **Rollout: incremental PRs behind the flag** (default `legacy`, flip to `new` once
  green, then delete legacy code).

---

## Interfaces that MUST be preserved (do not change signatures)

```ruby
LinkExpansion.by_edition(edition, with_drafts: false)            # => responds_to :links_with_content
LinkExpansion.by_content_id(content_id, locale: Edition::DEFAULT_LOCALE, with_drafts: false)
#links_with_content   # nested hash: { link_type => [ expanded_edition_hash.merge(links: {...}) ] }

DependencyResolution.new(content_id, locale: Edition::DEFAULT_LOCALE, with_drafts: false)
#dependencies         # flat Array of content_ids

LinkExpansion::EditionDiff           # RETAINED, used by PutContent / Publish — untouched
```

`Queries::ContentDependencies` (`app/queries/content_dependencies.rb`) and
`DependencyResolutionJob` / `HostContentUpdateJob` stay **as-is** — they just call the new
internals.

---

## Key design decisions (the tricky bits — read before coding)

### 1. Cycle prevention is PER-PATH, not a global "visited set"
The ADR loosely says "visited set", but a naive global visited set **changes the output**
and would break parity. Proof: the cyclic test in
`spec/integration/link_expansion_spec.rb` (a `-parent-> b`, b `-parent-> a`) expects the
root `a` to reappear as `b`'s `parent` child (expanded one level, its own children
pruned). A global visited set would have excluded `a` from `b`'s children entirely.

Legacy excludes only the **ancestors along the current path** (`parent_content_ids` in
`Queries::Links#where_not`, sourced from `LinkGraph::Node#parent_content_ids`). The same
`content_id` can legitimately appear in multiple branches with different expanded fields,
and a node's allowed next link types depend on its `link_types_path`.

**Design:** each BFS frontier node carries an `ancestors` array (content_ids from root to
its parent inclusive). After each batched level query, drop any result Edition whose
`content_id ∈ node.ancestors`. Children inherit `ancestors + [parent.content_id]`. This
reproduces legacy's `WHERE NOT IN (parent_content_ids)` exactly, filtered in Ruby
post-query (the ADR's accepted trade-off — cycles are rare, so a few extra fetched-then-
filtered rows are cheap and keep the SQL simple). Applies to **both** link expansion and
dependency resolution (dep-res output is a flat set, but per-path ancestors are still
needed to bound traversal and match which paths legacy actually walked).

### 2. Root expands ALL present link types → root direct-link-type discovery is required
GraphQL never needs this (the schema names every link field). Legacy discovers them from
data: `Queries::Links.from(content_id, allowed_link_types: nil)` (link_set links) +
`Queries::EditionLinks.from` (edition links). The batch SQL requires explicit link types
in its `query_input`, so the BFS needs a cheap discovery query at the root:

```ruby
Link.where(link_set_content_id: content_id)
    .or(Link.where(edition_id: root_edition_id))   # OR-branch only if root_edition_id present
    .distinct.pluck(:link_type)
```

Root **reverse** link types are the fixed `ExpansionRules.reverse_links` set (no
discovery). Child levels (1+) get their link types from
`allowed_direct_link_types(path)` / `allowed_reverse_link_types(path)` — no discovery.

### 3. Edition links only at root → pass `edition_id: NULL` at child levels
The forward SQL's `edition_linked_editions` CTE joins
`source_editions.id = query_input.edition_id`; a NULL `edition_id` matches nothing, so only
link_set links return. The BFS **input builder** does this nulling for non-root nodes
(NOT the shared query class — GraphQL intentionally follows edition links at all levels and
must stay byte-for-byte unchanged). Covered by `spec/integration/edition_links_spec.rb`.

### 4. Reverse links: query with the DIRECT type, record the REVERSE name
`MULTI_LEVEL_LINK_PATHS` uses reverse names (`:children`, `:child_taxons`,
`:part_of_step_navs`…). For a reverse link, query `reverse_linked_to_editions.sql` with the
direct stored type (`:parent`) but record the node's path-facing `link_type` as the reverse
name via `ExpansionRules.reverse_link_type`. Watch the fan-out:
`reverse_to_direct_link_type(:role_appointments) => [:person, :role]` (one reverse type →
two direct query types, re-keyed back to one `:role_appointments` bucket). Pass the
path-facing (reverse) name to `expand_fields` — some `CUSTOM_EXPANSION_FIELDS` entries are
keyed on reverse names (`:part_of_step_navs`, `:related_to_step_navs`), matching legacy.

### 5. `withdrawn` for SQL-sourced editions = `state == "unpublished"`
The SQL only returns an unpublished edition when it is a genuine withdrawal for a permitted
link type (`unpublishings.type = 'withdrawal'` guard). So `withdrawn` is just
`state == "unpublished"`. `LinkExpansion::EditionHash.from(edition)` computes `withdrawn`
from a `"unpublishings.type"` column that `find_by_sql` editions don't carry (→ would be
wrong), so override it for the SQL path. The SQL WHERE clause already enforces legacy's
`should_link?` filter at the DB level, so keep an equivalent guard only for the **root**
edition injected by `auto_reverse_link` (it is not fetched through the link SQL).

### 6. RETAIN `LinkExpansion::EditionHash` (ADR's deletion list is wrong here)
`lib/graphql/auto_reverse_linker.rb:51` calls `LinkExpansion::EditionHash.from(@edition)`.
The new expander also reuses it for Edition→hash conversion. **Do not delete it.** Note the
correction against the ADR's "Removed code" table.

### 7. Root edition resolution for `by_content_id`
Resolve the best root edition (locale + state fallback) to get `root_edition_id` (for root
edition links) and the root Edition object (for `auto_reverse_link` and discovery). Reuse
`Queries::GetEditionIdsWithFallbacks.call([content_id], locale_fallback_order: [locale,
DEFAULT_LOCALE].uniq, state_fallback_order: with_drafts ? %i[draft published withdrawn] :
%i[published withdrawn])`, then load the Edition. If none renderable: `root_edition_id =
nil` (only link_set + reverse links expand at root; no `auto_reverse_link`) — mirrors
legacy `ContentCache#find` returning nil.

---

## New code

### Shared SQL query classes (PR-1)
Move the SQL out of the GraphQL tree (text unchanged):
- `app/graphql/sources/queries/linked_to_editions.sql` → `app/queries/sql/linked_to_editions.sql`
- `app/graphql/sources/queries/reverse_linked_to_editions.sql` → `app/queries/sql/reverse_linked_to_editions.sql`
- `app/graphql/sources/queries/README.md` → `app/queries/sql/README.md`

Two thin primitives owning `query_input` JSON, `sql_params`, `Edition.find_by_sql`, dedup,
and grouping (mirroring the current `Sources::*#fetch` bodies):

```ruby
# app/queries/linked_to_editions.rb   (forward)
Queries::LinkedToEditions.new(locale:, with_drafts: false)
  #call(editions_and_link_types)  # => Hash{ [source_content_id, link_type] => [Edition,...] }
                                  #    pre-seeded with [] for every input key

# app/queries/reverse_linked_to_editions.rb   (reverse)
Queries::ReverseLinkedToEditions.new(locale:, with_drafts: false)
  #call(editions_and_link_types)  # => Hash{ [target_content_id, link_type] => [Edition,...] }
```

- `editions_and_link_types` = array of `[edition_like, link_type_string]`. `edition_like`
  responds to `#id` (may be nil) and `#content_id`. The expander passes a tiny struct at
  root (carrying `root_edition_id`/nil and the root content_id) and found Editions at child
  levels.
- `sql_params` exactly as today (`primary_locale: locale`, `secondary_locale:
  Edition::DEFAULT_LOCALE`, `permitted_not_unpublished_states`, `unpublished_link_types:
  Link::PERMITTED_UNPUBLISHED_LINK_TYPES`, `non_renderable_formats:
  Edition::NON_RENDERABLE_FORMATS`).
- Keep the `[]`-seeding-per-input behaviour so missing results yield `[]` and order matches
  input — the GraphQL Dataloader relies on this (returns `.values`), and the BFS benefits too.
- The class stays a neutral primitive: it does **not** null `edition_id` (that is the BFS
  input builder's job).

### BFS link expander (PR-2)
New `LinkExpansion::BreadthFirstExpander` (built alongside legacy; `LinkExpansion`
dispatches to it behind the flag — see Rollout). Reuse the existing
`ExpansionRules.*` and `LinkExpansion::EditionHash`.

Frontier node (plain struct): `edition`, `content_id`, `edition_id`, `link_type`
(path-facing), `link_types_path`, `ancestors`, plus a reference to the parent's emitted
`links: {}` hash so children attach into the output tree top-down.

Per-level algorithm (level n → n+1):
1. For each frontier node compute `allowed_direct_link_types(path)` and
   `allowed_reverse_link_types(path)` (via `ExpansionRules.link_expansion`).
2. Build **one** forward batch: per `(node, direct_type)`, push input with `content_id:
   node.content_id` and `edition_id: NULL` for all non-root nodes. Call
   `Queries::LinkedToEditions#call` once.
3. Build **one** reverse batch: per `(node, reverse_type)`, expand reverse → direct via
   `reverse_to_direct_link_type`, push `[node, direct_type]`. Call
   `Queries::ReverseLinkedToEditions#call` once; re-key each `(content_id, direct_type)`
   result to its reverse name for the node's path-facing `link_type`.
4. Per node, gather forward + reverse results in legacy key-insertion order (root: reverse,
   then direct; child: direct, then reverse). Within a `(content_id, link_type)` bucket the
   SQL `ORDER BY link_type ASC, position ASC, link_id DESC` already gives correct order.
5. Cycle filter: drop results whose `content_id ∈ node.ancestors`.
6. Convert each survivor Edition → hash, `ExpansionRules.expand_fields(hash, link_type:
   path_facing, draft: with_drafts)`, emit `expanded.merge(links: {})`, attach into the
   parent's links hash, and push a child frontier node.
7. Terminate when the new frontier is empty (`allowed_*` returns `[]` once a path leaves
   `MULTI_LEVEL_LINK_PATHS`, naturally bounding depth).

Level 0 specifics: resolve root edition (decision 7); direct types via discovery query
(decision 2) with `edition_id: root_edition_id`; reverse types = `reverse_links`.

`auto_reverse_link` post-processing (decision 4 of ADR): after BFS, for each **level-1**
node whose `link_type` is a reverse type, for each `D ∈ reverse_to_direct_link_type(R)`,
set `node.links[D] = [ expand_fields(root_hash, link_type: D, draft:).merge(links: {}) ]`,
guarded by the root `should_link?`. Skip entirely if no renderable root edition.

Edition→hash: `EditionHash.from(edition)` then override `hash[:withdrawn] =
(edition.state == "unpublished")` (or add `EditionHash.from_sql_edition`). `content_id`,
`locale`, `api_path` already come out correct.

### BFS dependency resolver (PR-3)
New `DependencyResolution::BreadthFirstResolver` (same engine, mirrored). Uses
`ExpansionRules.dependency_resolution` (`backwards: true`) for path validation. Directions
swapped vs link expansion:
- Root "direct deps" = REVERSE query, link types **discovered** from
  `Link.where(target_content_id: content_id).distinct.pluck(:link_type)`.
- Root "reverse deps" = FORWARD query restricted to
  `reverse_to_direct_link_types(reverse_links)`.
- Child levels: reverse-then-direct, `edition_id: NULL` on the forward branch.
- Output: collect `content_id`s only (no field expansion / hash / auto_reverse_link),
  `uniq` at the end. Re-keying still needed for path validation.

`DependencyResolution#dependencies` returns the flat list as today.

---

## Changes to existing code

- **`app/graphql/sources/linked_to_editions_source.rb`** and
  **`reverse_linked_to_editions_source.rb`** (PR-1): drop the inline `SQL`/`sql_params`/
  `find_by_sql`/grouping; `fetch` delegates to the shared query class and returns
  `result_hash.values` (preserving the Dataloader contract and input ordering). Still pass
  real non-null `edition.id` at every level (GraphQL behaviour unchanged). **Gate:**
  `spec/integration/graphql/link_expansion/*` and all GraphQL specs stay green.
- **`lib/link_expansion.rb`** (PR-2): add the `legacy | new` dispatch in `by_edition` /
  `by_content_id` (or in `links_with_content`).
- **`lib/dependency_resolution.rb`** (PR-3): add the `legacy | new` dispatch in
  `#dependencies`.

The toggle: a single env/config switch (e.g. `LINK_EXPANSION_IMPLEMENTATION=legacy|new`,
default `legacy`), read once. No shadow/compare path (per the test/CI-only decision).

---

## Removed code (PR-6, after the flag default flips to `new`)

| Delete | Spec to delete |
|---|---|
| `app/models/link_graph.rb` | `spec/models/link_graph_spec.rb` |
| `app/models/link_graph/node.rb` | — |
| `app/models/link_graph/node_collection_factory.rb` | — |
| `lib/link_expansion/link_reference.rb` | `spec/lib/link_expansion/link_reference_spec.rb` |
| `lib/link_expansion/content_cache.rb` | — |
| `lib/dependency_resolution/link_reference.rb` | `spec/lib/dependency_resolution/link_reference_spec.rb` |
| `app/queries/links.rb` | `spec/queries/links_spec.rb` |
| `app/queries/edition_links.rb` | `spec/queries/edition_links_spec.rb` |

Also remove the now-dead `legacy|new` dispatch/flag.

**Keep (corrections / retentions):** `lib/link_expansion/edition_hash.rb` (decision 6),
`lib/link_expansion/edition_diff.rb`, all of `lib/expansion_rules*`,
`app/queries/content_dependencies.rb`, `app/queries/get_edition_ids_with_fallbacks.rb`,
`app/sidekiq/dependency_resolution_job.rb`.

---

## Test changes

- **PR-0 (first, no production code):** add an integration tiebreaking test to
  `spec/integration/link_expansion_spec.rb` — two links of the same `link_type` with
  `position: 0` on the root link set; assert the expanded array orders the higher `link_id`
  first (mirrors the deleted `spec/queries/links_spec.rb:45-56`). Add a matching reverse-link
  assertion (the reverse SQL also orders `link_id DESC`). Must pass on legacy, then guards
  the new code. This fills the coverage gap the ADR flags before the refactor begins.
- **New unit specs:** `spec/queries/linked_to_editions_spec.rb`,
  `spec/queries/reverse_linked_to_editions_spec.rb` (query_input construction, `edition_id:
  NULL` handling, grouping keys, seeded empties, dedup — replacing the lost SQL-level
  coverage); `spec/lib/link_expansion/breadth_first_expander_spec.rb` (level batching,
  reverse re-keying incl. `role_appointments`→`person`/`role`, per-path ancestor cycle
  filtering, auto_reverse_link, root discovery, no-renderable-root, withdrawn correctness);
  `spec/lib/dependency_resolution/breadth_first_resolver_spec.rb` (multi-level path chains,
  reverse `child_taxons`, cycles).
- **Unchanged parity contract** (run against `new` in CI): `spec/integration/link_expansion_spec.rb`,
  `spec/lib/link_expansion_spec.rb`, `spec/integration/edition_links_spec.rb`,
  `spec/integration/dependency_resolution_spec.rb`, `spec/queries/content_dependencies_spec.rb`,
  `spec/integration/graphql/link_expansion/*`.
- **CI:** add a parameterized run of the integration suites with the flag set to `new`
  (e.g. a matrix axis), so parity is enforced automatically during the transition.

---

## PR sequencing

- **PR-0** — Integration tiebreaking test(s). Green on legacy.
- **PR-1** — Extract shared SQL to `app/queries/sql/`; add `Queries::LinkedToEditions` /
  `ReverseLinkedToEditions`; rewire the two GraphQL `Sources::*` to delegate. No behaviour
  change. Gate: GraphQL parity suite green. Independently shippable.
- **PR-2** — `LinkExpansion::BreadthFirstExpander` + `legacy|new` dispatch (default
  legacy) + new unit specs. CI runs integration suites against `new`.
- **PR-3** — `DependencyResolution::BreadthFirstResolver` + dispatch (default legacy) +
  specs.
- **PR-4** — Flip the flag default to `new`. Keep legacy one release for rollback; monitor.
- **PR-5** — Remove legacy code + specs (table above); remove the dead flag; update docs.

---

## Docs (PR-5)

- `docs/link-expansion.md`: replace the LinkGraph/depth-first description with the BFS +
  two-batch-SQL model; note edition links are followed only at root (`edition_id: NULL` at
  child levels) as the deliberate legacy-preserving choice.
- `docs/dependency-resolution.md`: update "how it works" to the reversed BFS. The
  `DependencyResolution#link_graph` console-debugging method goes away — replace its mention
  with: `LinkExpansion.by_content_id(id).links_with_content` for inspecting the expanded
  tree, and `DependencyResolution.new(id).dependencies` for the flat list; optionally add a
  lightweight `#debug_tree` on the new resolver that prints the per-level frontier
  (link types + paths). Fix the doc's `[link-graph]` anchor.

---

## Verification (end-to-end)

1. `bundle exec rspec spec/integration/link_expansion_spec.rb spec/lib/link_expansion_spec.rb
   spec/integration/edition_links_spec.rb spec/integration/dependency_resolution_spec.rb
   spec/queries/content_dependencies_spec.rb spec/integration/graphql/link_expansion`
   — run with the flag at both `legacy` and `new`; both must be green.
2. `bundle exec rake` (rubocop + rspec + pact:verify) — the Content Store pact consumer
   tests exercise the presented expanded links end-to-end.
3. Manual smoke in a Rails console against a GOV.UK DB dump: pick a richly-linked content_id
   (e.g. a taxon or a person), compare
   `LinkExpansion.by_content_id(id).links_with_content` and
   `DependencyResolution.new(id).dependencies` between `legacy` and `new`; confirm equal
   output and observe the query-count drop (e.g. wrap in `ActiveRecord` query logging /
   `count_queries`).
4. Confirm GraphQL `/graphql` link fields are unchanged after PR-1 (the SQL extraction is
   behaviour-preserving).

---

## Risks (highest first)

1. **Cycle semantics** — must be per-path ancestors, not a global visited set; get the
   cyclic integration test green before flipping the flag.
2. **Reverse re-keying / `role_appointments` fan-out** — one reverse type → two direct
   query types, re-keyed to one bucket; also `auto_reverse_linker.rb` special-cases
   `role_appointments` as a top-level (non-reverse) link — ensure root discovery vs reverse
   set don't double-count it.
3. **`edition_id: NULL` at child levels only** — applied by the BFS input builder, not the
   shared query class, so GraphQL stays identical.
4. **`withdrawn` for SQL-sourced editions** — override to `state == "unpublished"`.
5. **Output key ordering** — match legacy merge order (root reverse-then-direct; child
   direct-then-reverse); within-bucket order is already guaranteed by the SQL.
6. **No-renderable-root path** — `edition_id NULL`, only link_set + reverse expand, no
   auto_reverse_link.
7. **GraphQL parity must not regress in PR-1** — the parity suite is the gate.
