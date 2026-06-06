# Resolves the root edition for link expansion: the caller-supplied edition
# (by_edition) or, failing that, the best edition for the content_id using the
# locale/state fallback (by_content_id — "decision 7"). It is loaded with its
# unpublishings.type column so LinkExpansion::EditionHash can derive `withdrawn`
# itself, the same way the batch SQL does for non-root editions.
class LinkExpansion::RootEdition
  def initialize(edition: nil, content_id: nil, locale: nil, with_drafts: false)
    @explicit_edition = edition
    @content_id = content_id
    @locale = locale
    @with_drafts = with_drafts
  end

  # The resolved Edition, or nil when there is no renderable edition. Memoised
  # (including the nil result) so the fallback query runs at most once.
  def edition
    return @edition if defined?(@edition)

    @edition = @explicit_edition || load
  end

  def id
    edition&.id
  end

private

  attr_reader :content_id, :locale, :with_drafts

  def load
    edition_ids = Queries::GetEditionIdsWithFallbacks.call(
      [content_id],
      locale_fallback_order: [locale, Edition::DEFAULT_LOCALE].uniq,
      state_fallback_order: with_drafts ? %i[draft published withdrawn] : %i[published withdrawn],
    )
    return nil if edition_ids.blank?

    Edition.with_document.with_unpublishing
      .select("editions.*", 'unpublishings.type AS "unpublishings.type"')
      .find_by(id: edition_ids.first)
  end
end
