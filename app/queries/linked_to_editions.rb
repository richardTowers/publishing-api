module Queries
  # Batch query for "direct" (forward) link expansion.
  #
  # Given a list of source editions and link types, returns the target editions
  # linked from each source via that link type. This is a thin primitive owning
  # the `query_input` JSON, `sql_params`, `Edition.find_by_sql`, dedup and
  # grouping. It is shared by the GraphQL `Sources::LinkedToEditionsSource`
  # dataloader and the breadth-first link expander.
  #
  # The class is a neutral primitive: it does NOT null out `edition_id` for
  # non-root nodes - that is the caller's (BFS input builder's) job.
  class LinkedToEditions
    SQL = File.read(Rails.root.join("app/queries/sql/linked_to_editions.sql"))

    def initialize(locale:, with_drafts: false)
      @primary_locale = locale
      @secondary_locale = Edition::DEFAULT_LOCALE
      @with_drafts = with_drafts
    end

    # editions_and_link_types: array of [edition_like, link_type]. edition_like
    # responds to #id (may be nil) and #content_id.
    #
    # Returns Hash{ [source_content_id, link_type] => [Edition, ...] }, pre-seeded
    # with [] for every input key so missing results yield [] and order matches
    # input.
    def call(editions_and_link_types)
      link_types_map = {}
      query_input = []
      editions_and_link_types.each do |edition, link_type|
        query_input.push({ edition_id: edition.id, content_id: edition.content_id, link_type: })
        link_types_map[[edition.content_id, link_type]] = []
      end

      return link_types_map if query_input.empty?

      sql_params = {
        query_input: query_input.to_json,
        query_input_count: query_input.count,
        primary_locale: @primary_locale,
        secondary_locale: @secondary_locale,
        permitted_not_unpublished_states: @with_drafts ? %i[draft published] : %i[published],
        unpublished_link_types: Link::PERMITTED_UNPUBLISHED_LINK_TYPES,
        non_renderable_formats: Edition::NON_RENDERABLE_FORMATS,
      }
      all_editions = Edition.find_by_sql([SQL, sql_params])
      all_editions.each(&:strict_loading!)
      all_editions.each_with_object(link_types_map) do |edition, hash|
        key = [edition.source_content_id, edition.link_type]
        hash[key] << edition unless hash[key].include?(edition)
      end
    end
  end
end
