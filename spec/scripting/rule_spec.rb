
# The store decides what may be saved and Rule decides what may be built, so a kind in
# one and not the other is a script that saves, enables, and then never runs.
RSpec.describe "the kinds a rule accepts" do
  it "matches the kinds the store will save" do
    expect(Rubotty::Scripting::Rule::KINDS.map(&:to_s))
      .to match_array(Rubotty::ControlPlane::Scripts::KINDS)
  end
end
