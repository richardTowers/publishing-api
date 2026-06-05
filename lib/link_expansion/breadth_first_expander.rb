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
    reverse_input = reverse_types.flat_map do |reverse_type|
      rules.reverse_to_direct_link_type(reverse_type).map { |direct| [root_ids, direct.to_s] }
    end

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
    # inputs) and carry them as [node, direct_types, reverse_types] tuples to the
    # distribution loop below, which reuses them.
    node_types = frontier.map do |node|
      direct_types = rules.link_expansion.allowed_direct_link_types(node.link_types_path)
      reverse_types = rules.link_expansion.allowed_reverse_link_types(node.link_types_path)

      # edition_id is NULL for non-root nodes: edition links are only followed
      # at the root (we don't support nested edition links).
      child_ids = EditionAndContentId.new(nil, node.content_id)
      direct_types.each { |type| forward_input << [child_ids, type.to_s] }
      reverse_types.each do |reverse_type|
        rules.reverse_to_direct_link_type(reverse_type).each do |direct|
          reverse_input << [child_ids, direct.to_s]
        end
      end

      [node, direct_types, reverse_types]
    end

    forward_results = forward_query.call(forward_input)
    reverse_results = reverse_query.call(reverse_input)

    next_frontier = []
    node_types.each do |node, direct_types, reverse_types|
      child_ancestors = node.ancestors + [node.content_id]
      # Child key order: direct links, then reverse links.
      direct_types.each do |type|
        editions = forward_results.fetch([node.content_id, type.to_s], [])
        attach(node.links, next_frontier, node.link_types_path, child_ancestors, type, editions)
      end

      reverse_types.each do |reverse_type|
        editions = reverse_editions(reverse_results, node.content_id, reverse_type)
        attach(node.links, next_frontier, node.link_types_path, child_ancestors, reverse_type, editions, child_reverse: true)
      end
    end

    next_frontier
  end

  # Gather (and re-key) the reverse results for one reverse link type. A reverse
  # type can fan out to several direct query types (e.g. :role_appointments =>
  # [:person, :role]); concatenate them in that order, re-keyed to the one
  # reverse bucket.
  def reverse_editions(reverse_results, source_content_id, reverse_type)
    rules.reverse_to_direct_link_type(reverse_type).flat_map do |direct|
      reverse_results.fetch([source_content_id, direct.to_s], [])
    end
  end

  # Convert each surviving edition to an expanded hash, attach it into the
  # parent's links hash under `link_type`, and (unless the edition was reached
  # via an edition link) push a child frontier node so its links expand too.
  #
  # `child_ancestors` is the set of content_ids the children must avoid (the
  # parent's own ancestors plus the parent itself), giving per-path cycle
  # pruning. `parent_path` is the parent node's link_types_path.
  #
  # Edition links are only followed at the root; the children of a node reached
  # via an edition link are never expanded ("we don't support nested edition
  # links"). At child levels the forward query passes edition_id: NULL so no
  # edition links come back; the reverse query has no such lever, so we drop
  # edition-sourced rows here when `child_reverse` is set.
  def attach(links, next_frontier, parent_path, child_ancestors, link_type, editions, child_reverse: false)
    editions = editions.reject { |edition| edition_link_sourced?(edition) } if child_reverse
    survivors = editions.reject { |edition| child_ancestors.include?(edition.content_id) }
    return if survivors.empty?

    links[link_type] = survivors.map do |edition|
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
    hash = LinkExpansion::EditionHash.from(edition)
    # SQL-sourced editions only come back unpublished when they are a genuine
    # withdrawal (the SQL enforces unpublishings.type = 'withdrawal'), and they
    # don't carry the "unpublishings.type" column EditionHash uses, so override.
    hash[:withdrawn] = edition.state == "unpublished"
    rules.expand_fields(hash, link_type:, draft: with_drafts)
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
                           hash = LinkExpansion::EditionHash.from(root_edition)
                           hash[:withdrawn] = root_edition.state == "unpublished"
                           hash
                         end
  end
end
