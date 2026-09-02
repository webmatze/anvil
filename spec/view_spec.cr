require "./spec_helper"

include Anvil

private def seg(n : Int32, pinned : Bool, prefix : String = "d")
  lines = (1..n).map { |i| Text.line("#{prefix}#{i}") }
  View::Segment.new(lines, pinned)
end

private def texts(lines)
  lines.map { |l| Text.plain(l) }
end

describe Anvil::View::Region do
  it "keeps everything that fits" do
    region = View::Region.compose([seg(2, false), seg(1, true, "p")], 10)
    texts(region).should eq ["d1", "d2", "p1"]
  end

  it "drops unpinned lines when it does not fit" do
    region = View::Region.compose([seg(10, false), seg(2, true, "p")], 6)
    # Pinned lines stay in any case.
    texts(region).should contain "p1"
    texts(region).should contain "p2"
    region.size.should be <= 6
  end

  it "drops the oldest first" do
    region = View::Region.compose([seg(6, false), seg(1, true, "p")], 5)
    t = texts(region)
    # d1..d3 are gone, the later ones still stand.
    t.should_not contain "d1"
    t.should contain "d6"
    t.last.should eq "p1"
  end

  it "leaves a marker saying how many are missing" do
    region = View::Region.compose([seg(10, false), seg(1, true, "p")], 5)
    texts(region).any?(&.includes?("more lines above")).should be_true
  end

  it "takes its own wording for the marker" do
    marker = ->(n : Int32) { Text.line("#{n} weg") }
    region = View::Region.compose([seg(10, false), seg(1, true, "p")], 5, marker)
    texts(region).any?(&.includes?("weg")).should be_true
  end

  it "keeps the bottom and the question above it when space runs out" do
    # Status bar and input are at the bottom; without them the user can do
    # nothing. The pinned first line is the question they answer.
    region = View::Region.compose([seg(1, true, "frage"), seg(5, false), seg(4, true, "tail")], 3)
    t = texts(region)
    t.size.should eq 3
    t.first.should eq "frage1"
    t.last.should eq "tail4"
  end

  it "keeps pinned lines even when they alone are too many" do
    # The input line must never vanish, or the user can do nothing.
    region = View::Region.compose([seg(3, false), seg(4, true, "p")], 2)
    texts(region).should contain "p4"
  end
end

describe Anvil::View::TextBlock do
  it "wraps its content to the width" do
    block = View::TextBlock.new("alpha beta gamma")
    texts(block.lines(11)).should eq ["alpha beta", "gamma"]
  end
end

record PopupItem, name : String, desc : String

private def popup(names = ["plan", "clear", "compact"])
  items = names.map { |n| PopupItem.new(n, "Beschreibung #{n}") }
  Anvil::Widgets::ListPopup(PopupItem).new(items, max_visible: 2,
    label: ->(i : PopupItem) { i.name },
    description: ->(i : PopupItem) { i.desc })
end

describe Anvil::Widgets::ListPopup do
  it "filters by substring, ignoring case" do
    p = popup
    p.update("CL")
    p.size.should eq 1
    p.current.try(&.name).should eq "clear"
  end

  it "closes when nothing matches" do
    p = popup
    p.update("zzz")
    p.open?.should be_false
  end

  it "wraps around when selecting" do
    p = popup
    p.update("")
    p.selected.should eq 0
    p.move_up
    p.selected.should eq 2
    p.move_down
    p.selected.should eq 0
  end

  it "keeps the selection inside the visible window" do
    p = popup
    p.update("")
    p.move_down
    p.move_down
    p.visible.map(&.name).should contain "compact"
  end

  it "keeps the selection in the window when wrapping upwards" do
    # Without following it, the window would stay put and the selection would
    # be gone.
    p = popup
    p.update("")
    p.move_up
    p.visible.map(&.name).should contain "compact"
  end

  it "truncates lines to the width" do
    p = popup
    p.update("")
    p.lines(12).each { |l| Text.width(l).should be <= 12 }
  end
end

describe "Anvil::Widgets::ListPopup Anpassbarkeit" do
  it "takes a filter of its own, ordering included" do
    items = [PopupItem.new("plan", "a"), PopupItem.new("compact", "b"), PopupItem.new("clear", "c")]
    prefix = ->(all : Array(PopupItem), q : String) do
      all.select { |i| i.name.starts_with?(q) }.sort_by(&.name)
    end
    p = Anvil::Widgets::ListPopup(PopupItem).new(items, label: ->(i : PopupItem) { i.name }, filter: prefix)
    p.update("c")
    p.matches.map(&.name).should eq ["clear", "compact"]
  end

  it "clamps the selection when wrap-around is not wanted" do
    items = [PopupItem.new("a", ""), PopupItem.new("b", "")]
    p = Anvil::Widgets::ListPopup(PopupItem).new(items, label: ->(i : PopupItem) { i.name },
      wrap_around: false)
    p.update("")
    p.move_up
    p.selected.should eq 0
    p.move_down
    p.move_down
    p.selected.should eq 1
  end

  it "does not scroll past the end" do
    # Otherwise the window shows blank rows below the last entry.
    items = (1..5).map { |i| PopupItem.new("i#{i}", "") }
    p = Anvil::Widgets::ListPopup(PopupItem).new(items, max_visible: 3,
      label: ->(i : PopupItem) { i.name })
    p.update("")
    4.times { p.move_down }
    p.top.should eq 2
    p.visible.size.should eq 3
  end
end
