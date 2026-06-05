#
# This is the core class of Dependency Resolution which is a complicated concept
# in the Publishing API
#
# The concept is documented in /docs/dependency-resolution.md
#
# This is a thin entry point; the traversal itself lives in
# DependencyResolution::BreadthFirstResolver.
#
class DependencyResolution
  attr_reader :content_id, :locale, :with_drafts

  def initialize(content_id, locale: Edition::DEFAULT_LOCALE, with_drafts: false)
    @content_id = content_id
    @locale = locale
    @with_drafts = with_drafts
  end

  def dependencies
    DependencyResolution::BreadthFirstResolver.new(
      content_id,
      locale:,
      with_drafts:,
    ).dependencies
  end
end
