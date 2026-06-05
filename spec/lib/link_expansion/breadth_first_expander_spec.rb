RSpec.describe LinkExpansion::BreadthFirstExpander do
  include DependencyResolutionHelper

  let(:a) { create_link_set }
  let(:b) { create_link_set }
  let(:c) { create_link_set }
  let(:d) { create_link_set }

  def expand(content_id, with_drafts: true)
    described_class.new(content_id:, locale: "en", with_drafts:).links_with_content
  end

  describe "parity with the legacy expander" do
    before do
      create_edition(a, "/a", factory: :draft_edition)
      create_edition(b, "/b", factory: :draft_edition)
      create_edition(c, "/c", factory: :draft_edition)
      create_edition(d, "/d", factory: :draft_edition)
    end

    it "matches the legacy output for a multi-level recursive chain" do
      create_link(a, b, "parent")
      create_link(b, c, "parent")
      create_link(c, d, "parent")

      legacy = LinkExpansion.new(content_id: a, locale: "en", with_drafts: true)
      legacy_output = legacy.send(:populate_links, legacy.link_graph.links)

      expect(expand(a)).to eq(legacy_output)
    end

    it "matches legacy for a cycle (per-path ancestor pruning, not a global visited set)" do
      create_link(a, b, "parent")
      create_link(b, a, "parent")

      legacy = LinkExpansion.new(content_id: a, locale: "en", with_drafts: true)
      legacy_output = legacy.send(:populate_links, legacy.link_graph.links)

      result = expand(a)
      expect(result).to eq(legacy_output)
      # the root reappears one level deep, with its own children pruned
      expect(result[:parent][0][:links][:parent][0][:links]).to eq({})
    end
  end

  describe "query count" do
    before do
      create_edition(a, "/a", factory: :draft_edition)
      create_edition(b, "/b", factory: :draft_edition)
      create_edition(c, "/c", factory: :draft_edition)
      create_edition(d, "/d", factory: :draft_edition)
      create_link(a, b, "parent")
      create_link(b, c, "parent")
      create_link(c, d, "parent")
    end

    it "issues a bounded number of queries (O(depth), not O(nodes))" do
      queries = []
      counter = lambda do |_name, _start, _finish, _id, payload|
        queries << payload[:sql] unless payload[:name] == "SCHEMA"
      end

      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        expand(a)
      end

      # Root resolution + discovery + (forward + reverse) per level. Far fewer
      # than the legacy one-query-per-node traversal.
      expect(queries.count).to be < 15
    end
  end

  describe "reverse re-keying with fan-out (role_appointments => person / role)" do
    it "buckets both the person and role reverse links under :role_appointments" do
      person = create_link_set
      role = create_link_set
      appointment = create_link_set

      create_edition(appointment, "/appointment", factory: :draft_edition, document_type: "role_appointment", schema_name: "role_appointment")
      create_edition(person, "/person", factory: :draft_edition, document_type: "person", schema_name: "person")
      create_edition(role, "/role", factory: :draft_edition, document_type: "ministerial_role", schema_name: "role")

      # The appointment links to both a person and a role (the stored, "direct"
      # link types). From the person's / role's point of view these are
      # role_appointments (the reverse name).
      create_link(appointment, person, "person")
      create_link(appointment, role, "role")

      person_links = expand(person)
      role_links = expand(role)

      expect(person_links[:role_appointments].map { _1[:base_path] }).to eq(["/appointment"])
      expect(role_links[:role_appointments].map { _1[:base_path] }).to eq(["/appointment"])
    end
  end

  describe "no renderable root edition" do
    it "still expands link set and reverse links without auto_reverse_link" do
      # No edition exists for `a`, but it has link set links and is linked to.
      create_edition(b, "/b", factory: :draft_edition)
      create_edition(c, "/c", factory: :draft_edition)
      create_link(a, b, "organisation") # link set link from a
      create_link(c, a, "parent")       # c is a child of a

      result = expand(a)

      expect(result[:organisation].map { _1[:base_path] }).to eq(["/b"])
      expect(result[:children].map { _1[:base_path] }).to eq(["/c"])
      # auto_reverse_link is skipped (no root edition to reverse-link back to)
      expect(result[:children][0][:links]).to eq({})
    end
  end
end
