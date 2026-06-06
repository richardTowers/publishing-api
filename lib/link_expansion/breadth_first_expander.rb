# Breadth-first link expansion.
#
# Builds the `links_with_content` tree using the two batch SQL queries shared
# with the GraphQL API (Queries::LinkedToEditions / ReverseLinkedToEditions).
# It walks the link graph one level at a time, issuing a small fixed number of
# queries per level (O(depth)) rather than one query per node (O(nodes)).
#
# See docs/link-expansion.md and the design notes in the ADR for the tricky
# bits (per-path cycle filtering, root link-type discovery, edition links only
# at root, reverse re-keying, and the withdrawn override).
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
    apply_auto_reverse_links(level_one_nodes)

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

    # Root key order: reverse links, then direct links.
    # Level-1 nodes carry empty ancestors: the root is never treated as a cycle
    # ancestor, so it can legitimately reappear deeper in the tree.
    reverse_types.each do |reverse_type|
      editions = reverse_editions(reverse_results, content_id, reverse_type)
      attach(root_links, next_frontier, [], [], reverse_type, editions)
    end

    direct_types.each do |type|
      editions = forward_results.fetch([content_id, type], [])
      attach(root_links, next_frontier, [], [], type.to_sym, editions)
    end

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
      child_ancestors = node.ancestors + [node.content_id]
      # Child key order: direct links, then reverse links.
      attach_direct(level_type, forward_results, next_frontier, child_ancestors)
      attach_reverse(level_type, reverse_results, next_frontier, child_ancestors)
    end

    next_frontier
  end

  def attach_direct(level_type, forward_results, next_frontier, child_ancestors)
    node = level_type.node
    level_type.direct_types.each do |type|
      editions = forward_results.fetch([node.content_id, type.to_s], [])
      attach(node.links, next_frontier, node.link_types_path, child_ancestors, type, editions)
    end
  end

  def attach_reverse(level_type, reverse_results, next_frontier, child_ancestors)
    node = level_type.node
    level_type.reverse_types.each do |reverse_type|
      editions = reverse_editions(reverse_results, node.content_id, reverse_type)
      attach(node.links, next_frontier, node.link_types_path, child_ancestors, reverse_type, editions, child_reverse: true)
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
  def attach(links, next_frontier, parent_path, child_ancestors, link_type, editions, child_reverse: false)
    survivors = survivors_for(editions, child_ancestors, child_reverse:)
    return if survivors.empty?

    links[link_type] = attach_survivors(survivors, next_frontier, parent_path, child_ancestors, link_type)
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

  # Build the emitted hash for each survivor and push its child frontier node.
  # `child_links` is the same hash object in both the emitted tree and the Node,
  # so descendants attach into the tree top-down. A node reached via an edition
  # link is marked terminal so its children are not expanded.
  def attach_survivors(survivors, next_frontier, parent_path, child_ancestors, link_type)
    survivors.map do |edition|
      child_links = {}
      next_frontier << Node.new(
        content_id: edition.content_id,
        link_type:,
        link_types_path: parent_path + [link_type],
        ancestors: child_ancestors,
        links: child_links,
        terminal: edition_link_sourced?(edition),
      )
      expand_fields(edition, link_type).merge(links: child_links)
    end
  end

  def edition_link_sourced?(edition)
    edition.link_source == "edition"
  end

  def expand_fields(edition, link_type)
    rules.expand_fields(sql_edition_hash(edition), link_type:, draft: with_drafts)
  end

  # An EditionHash for an edition sourced from the batch SQL. Such editions only
  # come back unpublished when they are a genuine withdrawal (the SQL enforces
  # unpublishings.type = 'withdrawal') and don't carry the "unpublishings.type"
  # column EditionHash derives `withdrawn` from, so set it explicitly. NOT used
  # for a caller-supplied edition (by_edition), which carries the real column.
  def sql_edition_hash(edition)
    hash = LinkExpansion::EditionHash.from(edition)
    hash[:withdrawn] = edition.state == "unpublished"
    hash
  end

  # --- auto_reverse_link ------------------------------------------------------

  def apply_auto_reverse_links(level_one_nodes)
    hash = root_edition_hash
    return unless hash

    level_one_nodes.each do |node|
      reverse_type = node.link_type
      next unless rules.is_reverse_link_type?(reverse_type)
      next unless should_link?(reverse_type, hash)

      rules.reverse_to_direct_link_type(reverse_type).each do |direct|
        expanded = rules.expand_fields(hash, link_type: direct, draft: with_drafts)
        node.links[direct] = [expanded.merge(links: {})]
      end
    end
  end

  def should_link?(link_type, edition_hash)
    Link::PERMITTED_UNPUBLISHED_LINK_TYPES.include?(link_type.to_s) ||
      edition_hash[:state] != "unpublished"
  end

  # --- root edition resolution (decision 7) -----------------------------------

  def root_edition
    return @root_edition if defined?(@root_edition)

    @root_edition = edition || load_root_edition
  end

  def root_edition_id
    root_edition&.id
  end

  def load_root_edition
    edition_ids = Queries::GetEditionIdsWithFallbacks.call(
      [content_id],
      locale_fallback_order: [locale, Edition::DEFAULT_LOCALE].uniq,
      state_fallback_order: with_drafts ? %i[draft published withdrawn] : %i[published withdrawn],
    )
    return nil if edition_ids.blank?

    Edition.with_document.find_by(id: edition_ids.first)
  end

  def root_edition_hash
    return @root_edition_hash if defined?(@root_edition_hash)

    @root_edition_hash = if root_edition.nil?
                           nil
                         elsif edition
                           # by_edition: use the in-memory edition as-is (the
                           # caller passed a fully-loaded edition object).
                           LinkExpansion::EditionHash.from(edition)
                         else
                           # by_content_id: root edition came from the database.
                           sql_edition_hash(root_edition)
                         end
  end
end
