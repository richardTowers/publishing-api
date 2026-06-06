# Breadth-first link expansion.
#
# Builds the `links_with_content` tree using the two batch SQL queries shared
# with the GraphQL API (Queries::LinkedToEditions / ReverseLinkedToEditions).
# It walks the link graph one level at a time, issuing a small fixed number of
# queries per level (O(depth)) rather than one query per node (O(nodes)).
#
# See docs/link-expansion.md and the design notes in the ADR for the tricky
# bits (per-path cycle filtering, root link-type discovery, edition links only
# at root, and reverse re-keying).
class LinkExpansion::BreadthFirstExpander
  # A node we have already emitted into the output tree and whose children we
  # still need to find. `links` is a reference to the emitted `links: {}` hash
  # so children attach into the tree top-down. Because that referenced hash is
  # mutated as children attach, a Node's value-based hash is unstable: never use
  # a Node as a Hash key or Set member.
  Node = Data.define(:content_id, :link_type, :link_types_path, :ancestors, :links, :terminal)

  # Minimal query input: responds to #id (the edition id, may be nil) and
  # #content_id, like an Edition does.
  EditionAndContentId = Data.define(:id, :content_id)

  # A frontier node plus the direct/reverse link types allowed at its path,
  # computed once while building a level's query inputs and reused when
  # distributing the results. Holds a Node, so the same "never use as a Hash
  # key or Set member" caveat applies.
  LevelTypes = Data.define(:node, :direct_types, :reverse_types)

  # The parent that a level's editions attach into: the destination `links`
  # hash, the `content_id` whose results we distribute, the parent's link-type
  # `parent_path` (children extend it), and the `child_ancestors` used to prune
  # cycles. Built for the root (empty path and ancestors, so the root is never a
  # cycle ancestor) and for each frontier node, which lets the root and the child
  # levels share attach_direct/attach_reverse. Holds the mutable `links` hash, so
  # the same "never use as a Hash key or Set member" caveat applies.
  AttachTarget = Data.define(:links, :content_id, :parent_path, :child_ancestors)

  def initialize(edition: nil, content_id: nil, locale: nil, with_drafts: false)
    @edition = edition
    @explicit_content_id = content_id
    @explicit_locale = locale
    @with_drafts = with_drafts
  end

  def links_with_content
    root_links = {}
    # Level-1 nodes include "terminal" ones reached via edition links: their
    # children are never expanded (we don't support nested edition links), but
    # auto_reverse_link still applies to them.
    level_one_nodes = expand_root(root_links)
    LinkExpansion::AutoReverseLinker.new(root_edition:, with_drafts:).apply(level_one_nodes)

    frontier = level_one_nodes.reject(&:terminal)
    frontier = expand_level(frontier) until frontier.empty?

    root_links
  end

private

  attr_reader :edition, :with_drafts

  def content_id
    edition ? edition.content_id : @explicit_content_id
  end

  def locale
    edition ? edition.locale : @explicit_locale
  end

  def rules
    ExpansionRules
  end

  def forward_query
    @forward_query ||= Queries::LinkedToEditions.new(locale:, with_drafts:)
  end

  def reverse_query
    @reverse_query ||= Queries::ReverseLinkedToEditions.new(locale:, with_drafts:)
  end

  # --- Level 0 (root) ---------------------------------------------------------

  def expand_root(root_links)
    root_ids = EditionAndContentId.new(root_edition_id, content_id)

    reverse_types = rules.reverse_links
    direct_types = discover_root_direct_link_types

    forward_input = direct_types.map { |type| [root_ids, type] }
    reverse_input = reverse_input_for(root_ids, reverse_types)

    forward_results = forward_query.call(forward_input)
    reverse_results = reverse_query.call(reverse_input)

    next_frontier = []

    # The root carries empty parent_path and child_ancestors: it is never treated
    # as a cycle ancestor, so it can legitimately reappear deeper in the tree.
    root = AttachTarget.new(links: root_links, content_id:, parent_path: [], child_ancestors: [])

    # Root key order: reverse links, then direct links. Edition links are
    # followed at the root, so reverse attachment here keeps edition-sourced rows
    # (child_reverse: false).
    attach_reverse(root, reverse_types, reverse_results, next_frontier, child_reverse: false)
    attach_direct(root, direct_types, forward_results, next_frontier)

    next_frontier
  end

  # The root expands all link types present in the data. The batch SQL needs
  # explicit link types, so discover them: link set links for the content_id,
  # plus edition links for the resolved root edition (if any).
  def discover_root_direct_link_types
    scope = Link.where(link_set_content_id: content_id)
    scope = scope.or(Link.where(edition_id: root_edition_id)) if root_edition_id
    scope.distinct.pluck(:link_type)
  end

  # --- Levels 1+ --------------------------------------------------------------

  def expand_level(frontier)
    forward_input = []
    reverse_input = []

    # Compute each node's link types once here (we need them to build the query
    # inputs) and carry them in a LevelTypes value object to the distribution
    # loop below, which reuses them.
    level_types = frontier.map do |node|
      direct_types = rules.link_expansion.allowed_direct_link_types(node.link_types_path)
      reverse_types = rules.link_expansion.allowed_reverse_link_types(node.link_types_path)

      # edition_id is NULL for non-root nodes: edition links are only followed
      # at the root (we don't support nested edition links).
      child_ids = EditionAndContentId.new(nil, node.content_id)
      direct_types.each { |type| forward_input << [child_ids, type.to_s] }
      reverse_input.concat(reverse_input_for(child_ids, reverse_types))

      LevelTypes.new(node:, direct_types:, reverse_types:)
    end

    forward_results = forward_query.call(forward_input)
    reverse_results = reverse_query.call(reverse_input)

    next_frontier = []
    level_types.each do |level_type|
      node = level_type.node
      target = AttachTarget.new(
        links: node.links,
        content_id: node.content_id,
        parent_path: node.link_types_path,
        child_ancestors: node.ancestors + [node.content_id],
      )
      # Child key order: direct links, then reverse links. Edition links are not
      # followed below the root, so reverse attachment drops edition-sourced rows
      # (child_reverse: true).
      attach_direct(target, level_type.direct_types, forward_results, next_frontier)
      attach_reverse(target, level_type.reverse_types, reverse_results, next_frontier, child_reverse: true)
    end

    next_frontier
  end

  # Distribute the forward-query results for one parent over its direct link
  # types. Shared by the root and the child levels; the type may arrive as a
  # string (root, from pluck) or a symbol (children), hence the to_s/to_sym.
  def attach_direct(target, direct_types, forward_results, next_frontier)
    direct_types.each do |type|
      editions = forward_results.fetch([target.content_id, type.to_s], [])
      attach(target, next_frontier, type.to_sym, editions)
    end
  end

  # Distribute the reverse-query results for one parent over its reverse link
  # types. Shared by the root and the child levels; child_reverse is true below
  # the root, where edition-sourced rows must be dropped (no nested edition links).
  def attach_reverse(target, reverse_types, reverse_results, next_frontier, child_reverse:)
    reverse_types.each do |reverse_type|
      editions = reverse_editions(reverse_results, target.content_id, reverse_type)
      attach(target, next_frontier, reverse_type, editions, child_reverse:)
    end
  end

  # Build the reverse query input for one set of ids over `reverse_types`. A
  # reverse link type can fan out to several direct query types (e.g.
  # :role_appointments => [:person, :role]); emit one input row per direct type,
  # in that order. Shared by the root and the child levels.
  def reverse_input_for(ids, reverse_types)
    reverse_types.flat_map do |reverse_type|
      rules.reverse_to_direct_link_type(reverse_type).map { |direct| [ids, direct.to_s] }
    end
  end

  # Gather (and re-key) the reverse results for one reverse link type, the
  # result-side counterpart of reverse_input_for: concatenate the rows for each
  # fanned-out direct type, in that order, re-keyed to the one reverse bucket.
  def reverse_editions(reverse_results, source_content_id, reverse_type)
    rules.reverse_to_direct_link_type(reverse_type).flat_map do |direct|
      reverse_results.fetch([source_content_id, direct.to_s], [])
    end
  end

  # Attach the surviving editions for `link_type` into the parent's `links` hash
  # and push a frontier node for each so its own links expand. Emits no key when
  # nothing survives: an absent key is meaningful and distinct from an empty [].
  # A node reached via an edition link is marked terminal so its children are not
  # expanded.
  def attach(target, next_frontier, link_type, editions, child_reverse: false)
    survivors = survivors_for(editions, target.child_ancestors, child_reverse:)
    return if survivors.empty?

    # Each survivor's child_links hash is shared between its frontier Node and its
    # emitted entry, so descendants attach into the tree top-down.
    survivors_with_links = survivors.map { |edition| [edition, {}] }

    survivors_with_links.each do |edition, child_links|
      next_frontier << Node.new(
        content_id: edition.content_id,
        link_type:,
        link_types_path: target.parent_path + [link_type],
        ancestors: target.child_ancestors,
        links: child_links,
        terminal: edition_link_sourced?(edition),
      )
    end

    target.links[link_type] = survivors_with_links.map do |edition, child_links|
      expand_fields(edition, link_type).merge(links: child_links)
    end
  end

  # The editions to actually attach. Per-path cycle pruning drops any whose
  # content_id is already on this path: `child_ancestors` is the parent's own
  # ancestors plus the parent itself.
  #
  # Edition links are only followed at the root, so the children of a node
  # reached via an edition link are never expanded ("no nested edition links").
  # The child-level forward query enforces this by passing edition_id: NULL; the
  # reverse query has no such lever, so we drop edition-sourced rows here when
  # `child_reverse` is set.
  def survivors_for(editions, child_ancestors, child_reverse:)
    editions = editions.reject { |edition| edition_link_sourced?(edition) } if child_reverse
    editions.reject { |edition| child_ancestors.include?(edition.content_id) }
  end

  def edition_link_sourced?(edition)
    edition.link_source == "edition"
  end

  def expand_fields(edition, link_type)
    rules.expand_fields(LinkExpansion::EditionHash.from(edition), link_type:, draft: with_drafts)
  end

  # --- root edition resolution (decision 7) -----------------------------------

  def root_edition
    root_edition_resolver.edition
  end

  def root_edition_id
    root_edition_resolver.id
  end

  def root_edition_resolver
    @root_edition_resolver ||= LinkExpansion::RootEdition.new(
      edition:, content_id:, locale:, with_drafts:,
    )
  end
end
