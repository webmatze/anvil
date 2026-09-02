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
  it "lässt alles stehen, was passt" do
    region = View::Region.compose([seg(2, false), seg(1, true, "p")], 10)
    texts(region).should eq ["d1", "d2", "p1"]
  end

  it "wirft nicht-angeheftete Zeilen weg, wenn es nicht passt" do
    region = View::Region.compose([seg(10, false), seg(2, true, "p")], 6)
    # Angeheftete bleiben in jedem Fall.
    texts(region).should contain "p1"
    texts(region).should contain "p2"
    region.size.should be <= 6
  end

  it "wirft die ältesten zuerst weg" do
    region = View::Region.compose([seg(6, false), seg(1, true, "p")], 5)
    t = texts(region)
    # d1..d3 sind weg, die späteren stehen noch.
    t.should_not contain "d1"
    t.should contain "d6"
    t.last.should eq "p1"
  end

  it "setzt eine Marke, die sagt wie viele fehlen" do
    region = View::Region.compose([seg(10, false), seg(1, true, "p")], 5)
    texts(region).any?(&.includes?("more lines above")).should be_true
  end

  it "nimmt einen eigenen Wortlaut für die Marke" do
    marker = ->(n : Int32) { Text.line("#{n} weg") }
    region = View::Region.compose([seg(10, false), seg(1, true, "p")], 5, marker)
    texts(region).any?(&.includes?("weg")).should be_true
  end

  it "behält bei zu wenig Platz das untere Ende und die Frage darüber" do
    # Statusleiste und Eingabe stehen unten; ohne sie kann der Nutzer nichts
    # tun. Die angeheftete erste Zeile ist die Frage, auf die sie sich beziehen.
    region = View::Region.compose([seg(1, true, "frage"), seg(5, false), seg(4, true, "tail")], 3)
    t = texts(region)
    t.size.should eq 3
    t.first.should eq "frage1"
    t.last.should eq "tail4"
  end

  it "behält angeheftete Zeilen auch dann, wenn sie allein schon zu viel sind" do
    # Die Eingabezeile darf nie verschwinden, sonst kann der Nutzer nichts tun.
    region = View::Region.compose([seg(3, false), seg(4, true, "p")], 2)
    texts(region).should contain "p4"
  end
end

describe Anvil::View::TextBlock do
  it "bricht seinen Inhalt auf die Breite um" do
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
  it "filtert nach Teilzeichenkette, ohne Groß-/Kleinschreibung" do
    p = popup
    p.update("CL")
    p.size.should eq 1
    p.current.try(&.name).should eq "clear"
  end

  it "schließt, wenn nichts passt" do
    p = popup
    p.update("zzz")
    p.open?.should be_false
  end

  it "läuft bei der Auswahl um" do
    p = popup
    p.update("")
    p.selected.should eq 0
    p.move_up
    p.selected.should eq 2
    p.move_down
    p.selected.should eq 0
  end

  it "hält die Auswahl im sichtbaren Fenster" do
    p = popup
    p.update("")
    p.move_down
    p.move_down
    p.visible.map(&.name).should contain "compact"
  end

  it "hält die Auswahl auch beim Umlauf nach oben im Fenster" do
    # Ohne Nachführen bliebe das Fenster oben stehen und die Auswahl wäre weg.
    p = popup
    p.update("")
    p.move_up
    p.visible.map(&.name).should contain "compact"
  end

  it "kürzt Zeilen auf die Breite" do
    p = popup
    p.update("")
    p.lines(12).each { |l| Text.width(l).should be <= 12 }
  end
end

describe "Anvil::Widgets::ListPopup Anpassbarkeit" do
  it "nimmt einen eigenen Filter samt Sortierung" do
    items = [PopupItem.new("plan", "a"), PopupItem.new("compact", "b"), PopupItem.new("clear", "c")]
    prefix = ->(all : Array(PopupItem), q : String) do
      all.select { |i| i.name.starts_with?(q) }.sort_by(&.name)
    end
    p = Anvil::Widgets::ListPopup(PopupItem).new(items, label: ->(i : PopupItem) { i.name }, filter: prefix)
    p.update("c")
    p.matches.map(&.name).should eq ["clear", "compact"]
  end

  it "klemmt die Auswahl, wenn kein Umlauf gewünscht ist" do
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

  it "scrollt nicht über das Ende hinaus" do
    # Sonst zeigt das Fenster Leerzeilen unter dem letzten Eintrag.
    items = (1..5).map { |i| PopupItem.new("i#{i}", "") }
    p = Anvil::Widgets::ListPopup(PopupItem).new(items, max_visible: 3,
      label: ->(i : PopupItem) { i.name })
    p.update("")
    4.times { p.move_down }
    p.top.should eq 2
    p.visible.size.should eq 3
  end
end
