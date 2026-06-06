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
  # Minimal query input: responds to #id (the edition id, may be nil) and
  # #content_id, like an Edition does.
  EditionAndContentId = Data.define(:id, :content_id)

  # A node in the expansion tree whose children we still need to find, which
  # also serves as the parent we attach a level's editions into. `links` is the
  # emitted `links: {}` hash, so children attach top-down. `excluded_content_ids`
  # are the content_ids on the path so far (including this node), used to prune
  # cycles. The root is the top node: empty path, nothing excluded, `links` is
  # the output root — so the root (never on the path) can reappear deeper.
  # `link_type`/`terminal` record the edge that reached the node (nil/false for
  # the root) and are read only for the level-1 nodes (auto-reverse linking and
  # the terminal filter).
  #
  # Because `links` is mutated as children attach, a Node's value-based hash is
  # unstable: never use a Node as a Hash key or Set member.
  Node = Data.define(:content_id, :link_type, :link_types_path, :excluded_content_ids, :links, :terminal)

  # A frontier node plus the direct/reverse link types allowed at its path,
  # computed once while building a level's query inputs and reused when
  # distributing the results. Holds a Node, so the same "never use as a Hash
  # key or Set member" caveat applies.
  NodeAndLinkTypes = Data.define(:node, :direct_types, :reverse_types)

  def initialize(edition: nil, content_id: nil, locale: nil, with_drafts: false)
    @edition = edition
    @content_id = edition&.content_id || content_id
    @locale = edition&.locale || locale
    @with_drafts = with_drafts
    @forward_query = Queries::LinkedToEditions.new(locale: @locale, with_drafts:)
    @reverse_query = Queries::ReverseLinkedToEditions.new(locale: @locale, with_drafts:)
    @rules = ExpansionRules
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

  attr_reader :edition, :content_id, :locale, :with_drafts, :forward_query, :reverse_query, :rules

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

    # The root is the top node: empty path, nothing excluded (it is never on the
    # path, so it can reappear deeper), and root_links as its links hash. It has
    # no incoming edge, hence nil link_type and terminal: false.
    root = Node.new(
      content_id:,
      link_type: nil,
      link_types_path: [],
      excluded_content_ids: [],
      links: root_links,
      terminal: false,
    )

    # Root key order: reverse links, then direct links. Edition links are
    # followed at the root, so reverse attachment here keeps edition-sourced rows
    # (child_reverse: false).
    attach_reverse(root, reverse_types, reverse_results, next_frontier, drop_edition_links: false)
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
    nodes_and_link_types = frontier.map do |node|
      direct_types = rules.link_expansion.allowed_direct_link_types(node.link_types_path)
      reverse_types = rules.link_expansion.allowed_reverse_link_types(node.link_types_path)

      # edition_id is NULL for non-root nodes: edition links are only followed
      # at the root (we don't support nested edition links).
      child_ids = EditionAndContentId.new(nil, node.content_id)
      direct_types.each { |type| forward_input << [child_ids, type.to_s] }
      reverse_input.concat(reverse_input_for(child_ids, reverse_types))

      NodeAndLinkTypes.new(node:, direct_types:, reverse_types:)
    end

    forward_results = forward_query.call(forward_input)
    reverse_results = reverse_query.call(reverse_input)

    next_frontier = []
    nodes_and_link_types.each do |level_type|
      node = level_type.node
      # The node is itself the parent we attach into. Child key order: direct
      # links, then reverse links. Edition links are not followed below the root,
      # so reverse attachment drops edition-sourced rows (child_reverse: true).
      attach_direct(node, level_type.direct_types, forward_results, next_frontier)
      attach_reverse(node, level_type.reverse_types, reverse_results, next_frontier, drop_edition_links: true)
    end

    next_frontier
  end

  # Distribute the forward-query results for one parent node over its direct link
  # types. Shared by the root and the child levels; the type may arrive as a
  # string (root, from pluck) or a symbol (children), hence the to_s/to_sym.
  def attach_direct(parent, direct_types, forward_results, next_frontier)
    direct_types.each do |type|
      editions = forward_results.fetch([parent.content_id, type.to_s], [])
      attach(parent, next_frontier, type.to_sym, editions)
    end
  end

  # Distribute the reverse-query results for one parent node over its reverse
  # link types. Shared by the root and the child levels; child_reverse is true
  # below the root, where edition-sourced rows must be dropped (no nested edition
  # links).
  def attach_reverse(parent, reverse_types, reverse_results, next_frontier, drop_edition_links:)
    reverse_types.each do |reverse_type|
      editions = reverse_editions(reverse_results, parent.content_id, reverse_type)
      attach(parent, next_frontier, reverse_type, editions, drop_edition_links:)
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
  def attach(parent, next_frontier, link_type, editions, drop_edition_links: false)
    survivors = survivors_for(editions, parent.excluded_content_ids, drop_edition_links:)
    return if survivors.empty?

    # Each survivor's child_links hash is shared between its frontier Node and its
    # emitted entry, so descendants attach into the tree top-down.
    survivors_with_links = survivors.map { |edition| [edition, {}] }

    survivors_with_links.each do |edition, child_links|
      next_frontier << Node.new(
        content_id: edition.content_id,
        link_type:,
        link_types_path: parent.link_types_path + [link_type],
        excluded_content_ids: parent.excluded_content_ids + [edition.content_id],
        links: child_links,
        terminal: edition_link_sourced?(edition),
      )
    end

    parent.links[link_type] = survivors_with_links.map do |edition, child_links|
      expand_fields(edition, link_type).merge(links: child_links)
    end
  end

  # The editions to actually attach. Per-path cycle pruning drops any whose
  # content_id is already on this path: `excluded_content_ids` is the parent's,
  # which already includes the parent itself.
  #
  # Edition links are only followed at the root, so the children of a node
  # reached via an edition link are never expanded ("no nested edition links").
  # The child-level forward query enforces this by passing edition_id: NULL; the
  # reverse query has no such lever, so we drop edition-sourced rows here when
  # `child_reverse` is set.
  def survivors_for(editions, excluded_content_ids, drop_edition_links:)
    editions = editions.reject { |edition| edition_link_sourced?(edition) } if drop_edition_links
    editions.reject { |edition| excluded_content_ids.include?(edition.content_id) }
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
