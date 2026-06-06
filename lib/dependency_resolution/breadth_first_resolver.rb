# Breadth-first dependency resolution ("link expansion in reverse"). Returns a
# flat Array of dependent content_ids, resolving each level of the graph with a
# small fixed number of queries (O(depth)) rather than one query per node.
#
# Unlike link expansion, dependency resolution works purely on the links graph:
# a dependent's content_id is returned whether or not it has a renderable
# edition, so this resolver reads the `links` table directly rather than the
# edition-joining batch SQL the expander uses. Edition links are only relevant
# at the root (child levels follow link set links only), so the root reuses the
# existing Queries::Links / Queries::EditionLinks and the recursive levels batch
# plain `links`-table reads. See PLAN.md / ADR-014.
class DependencyResolution::BreadthFirstResolver
  Node = Data.define(:content_id, :link_types_path, :excluded_content_ids, :terminal)

  def initialize(content_id, locale:, with_drafts: false)
    @content_id = content_id
    @locale = locale
    @with_drafts = with_drafts
  end

  def dependencies
    @dependencies = []
    # Level-1 nodes reached via edition links are "terminal": their children are
    # never expanded (we don't support nested edition links).
    frontier = expand_root.reject(&:terminal)
    frontier = expand_level(frontier) until frontier.empty?
    @dependencies.uniq
  end

private

  attr_reader :content_id, :locale, :with_drafts

  def rules
    ExpansionRules
  end

  # ExpansionRules for dependency resolution walks the multi-level paths
  # backwards.
  def dr
    rules.dependency_resolution
  end

  # --- Level 0 (root) ---------------------------------------------------------
  #
  # Reuses the existing link-table queries. "Direct" dependencies are things
  # that link TO us; "reverse" dependencies are things we link to that
  # reciprocate via an automatic reverse link (so we record them under the
  # reverse link name).
  def expand_root
    outgoing_link_types = rules.reverse_to_direct_link_types(rules.reverse_links)

    incoming_link_set = Queries::Links.to(content_id)
    outgoing_link_set = rules.reverse_link_types_hash(
      Queries::Links.from(content_id, allowed_link_types: outgoing_link_types),
    )
    incoming_edition = Queries::EditionLinks.to(
      content_id, locale:, with_drafts:, allowed_link_types: nil
    )
    outgoing_edition = rules.reverse_link_types_hash(
      Queries::EditionLinks.from(
        content_id, locale:, with_drafts:, allowed_link_types: outgoing_link_types
      ),
    )

    frontier = []
    # Link set sources can be expanded further; edition sources are terminal.
    collect_root(frontier, incoming_link_set, terminal: false)
    collect_root(frontier, outgoing_link_set, terminal: false)
    collect_root(frontier, incoming_edition, terminal: true)
    collect_root(frontier, outgoing_edition, terminal: true)
    frontier
  end

  def collect_root(frontier, links_by_link_type, terminal:)
    links_by_link_type.each do |link_type, links|
      links.each do |link|
        dependency = link[:content_id]
        @dependencies << dependency
        # A level-1 node excludes only itself; the root's content_id is never
        # added to any exclusion set, so it can legitimately reappear deeper in
        # the graph.
        frontier << Node.new(
          content_id: dependency,
          link_types_path: [link_type],
          excluded_content_ids: [dependency],
          terminal:,
        )
      end
    end
  end

  # --- Levels 1+ --------------------------------------------------------------
  #
  # Pure link-set traversal, batched across the whole frontier: one query for
  # incoming links and one for outgoing links per level.
  def expand_level(frontier)
    content_ids = frontier.map(&:content_id).uniq

    incoming = Link.link_set_links
      .where(target_content_id: content_ids)
      .pluck(:target_content_id, :link_type, :link_set_content_id)
      .group_by(&:first)

    outgoing = Link.link_set_links
      .where(link_set_content_id: content_ids)
      .pluck(:link_set_content_id, :link_type, :target_content_id)
      .group_by(&:first)

    next_frontier = []
    frontier.each do |node|
      # "Direct" dependencies: things linking to this node. The path-facing link
      # type is the stored (incoming) type.
      allowed_direct = dr.allowed_direct_link_types(node.link_types_path).map(&:to_s)
      incoming.fetch(node.content_id, []).each do |(_target, link_type, source)|
        next unless allowed_direct.include?(link_type)

        add_dependency(next_frontier, source, node, link_type.to_sym)
      end

      # "Reverse" dependencies: things this node links to that reciprocate. The
      # path-facing link type is the reverse name.
      reverse_name_for = reverse_name_lookup(node.link_types_path)
      outgoing.fetch(node.content_id, []).each do |(_source, link_type, target)|
        reverse_name = reverse_name_for[link_type]
        next unless reverse_name

        add_dependency(next_frontier, target, node, reverse_name)
      end
    end

    next_frontier
  end

  # Maps each direct (stored) link type to the reverse name it should be
  # recorded under, for the reverse link types allowed at this path.
  def reverse_name_lookup(link_types_path)
    dr.allowed_reverse_link_types(link_types_path).each_with_object({}) do |reverse_type, memo|
      rules.reverse_to_direct_link_type(reverse_type).each do |direct|
        memo[direct.to_s] = reverse_type
      end
    end
  end

  def add_dependency(frontier, dependency, parent, link_type)
    return if parent.excluded_content_ids.include?(dependency)

    @dependencies << dependency
    frontier << Node.new(
      content_id: dependency,
      link_types_path: parent.link_types_path + [link_type],
      excluded_content_ids: parent.excluded_content_ids + [dependency],
      terminal: false,
    )
  end
end
