require "spec"
require "../src/anvil/text"

include Anvil

private def plain(lines : Array(Text::StyledLine)) : Array(String)
  lines.map { |l| Text.plain(l) }
end

describe Anvil::Text do
  describe ".width" do
    it "zählt ASCII als eine Spalte je Zeichen" do
      Text.width("hallo").should eq 5
    end

    it "zählt CJK als zwei Spalten" do
      Text.width("中文").should eq 4
    end

    it "zählt ein Emoji als zwei Spalten, nicht als zwei Zeichen" do
      Text.width("🙂").should eq 2
    end

    it "zählt kombinierende Zeichen nicht mit" do
      # e + combining acute ist ein Grapheme, eine Spalte.
      Text.width("é").should eq 1
    end
  end

  describe ".truncate" do
    it "lässt kurze Zeilen unangetastet" do
      line = Text.line("kurz")
      Text.truncate(line, 10).should eq line
    end

    it "schneidet auf die Breite" do
      Text.plain(Text.truncate(Text.line("abcdefgh"), 3)).should eq "abc"
    end

    it "hält Platz für das Kürzel frei" do
      Text.plain(Text.truncate(Text.line("abcdefgh"), 5, "…")).should eq "abcd…"
    end

    it "schneidet nie mitten in ein zweispaltiges Zeichen" do
      # Bei Breite 3 passt nur ein CJK-Zeichen; das zweite würde überstehen.
      Text.plain(Text.truncate(Text.line("中文字"), 3)).should eq "中"
    end

    it "schneidet über Span-Grenzen hinweg und behält die Stile" do
      line = [Text::Span.new("ab", Text::Style.new(bold: true)),
              Text::Span.new("cdef")]
      cut = Text.truncate(line, 3)
      Text.plain(cut).should eq "abc"
      cut.first.style.bold?.should be_true
      cut.last.style.bold?.should be_false
    end
  end

  describe ".wrap" do
    it "lässt passende Zeilen in einem Stück" do
      plain(Text.wrap(Text.line("kurz genug"), 20)).should eq ["kurz genug"]
    end

    it "bricht an Wortgrenzen" do
      plain(Text.wrap(Text.line("das ist ein test"), 8)).should eq ["das ist", "ein test"]
    end

    it "erzeugt nie eine Zeile breiter als erlaubt" do
      lines = Text.wrap(Text.line("alpha beta gamma delta epsilon zeta"), 11)
      lines.each { |l| Text.width(l).should be <= 11 }
    end

    it "trennt ein zu langes Wort hart, statt zu überlaufen" do
      lines = Text.wrap(Text.line("donaudampfschiff"), 6)
      plain(lines).should eq ["donaud", "ampfsc", "hiff"]
      lines.each { |l| Text.width(l).should be <= 6 }
    end

    it "hält ein Wort zusammen, das über eine Span-Grenze geht" do
      # "Hallo" ist auf zwei Spans verteilt und darf nicht getrennt werden.
      line = [Text::Span.new("Hal", Text::Style.new(bold: true)),
              Text::Span.new("lo Welt")]
      lines = Text.wrap(line, 7)
      plain(lines).should eq ["Hallo", "Welt"]
      # Der Stil des ersten Teils muss erhalten bleiben.
      lines.first.first.style.bold?.should be_true
    end

    it "rückt Folgezeilen nicht ein" do
      plain(Text.wrap(Text.line("aaa   bbb"), 4)).should eq ["aaa", "bbb"]
    end

    it "rechnet mit CJK-Breiten statt mit Zeichenzahl" do
      lines = Text.wrap(Text.line("中文 字体"), 4)
      lines.each { |l| Text.width(l).should be <= 4 }
      plain(lines).should eq ["中文", "字体"]
    end

    it "fasst gleich gestylte Grapheme zu einem Span zusammen" do
      # Sonst bekäme der Renderer pro Zeichen einen Batch.
      lines = Text.wrap(Text.line("donaudampfschiff"), 6)
      lines.first.size.should eq 1
    end
  end

  describe Anvil::Text::Style do
    it "merge lässt den anderen Stil gewinnen und addiert Attribute" do
      a = Text::Style.new(fg: Text::Palette::INFO, bold: true)
      b = Text::Style.new(fg: Text::Palette::ERROR, italic: true)
      m = a.merge(b)
      m.fg.should eq Text::Palette::ERROR
      m.bold?.should be_true
      m.attr.italic?.should be_true
    end

    it "merge behält, was der andere nicht setzt" do
      a = Text::Style.new(fg: Text::Palette::INFO)
      a.merge(Text::Style.new(bold: true)).fg.should eq Text::Palette::INFO
    end
  end
end

describe "Anvil::Text ANSI-Ausgabe" do
  it "gibt für einen leeren Stil nichts aus" do
    Text::Style::NONE.ansi.should eq ""
  end

  it "fasst Attribute und Farbe in einer Sequenz zusammen" do
    ansi = Text::Style.new(fg: Text::Color.ansi256(42), bold: true).ansi
    ansi.should start_with "\e["
    ansi.should end_with "m"
    ansi.should contain "1"
    ansi.should contain "38;5;42"
  end

  it "kennt TrueColor und die Grundfarben" do
    Text::Style.new(fg: Text::Color.rgb(1, 2, 3)).ansi.should contain "38;2;1;2;3"
    Text::Style.new(bg: Text::Color.ansi256(7)).ansi.should contain "48;5;7"
  end

  it "setzt zwischen zwei Stilen zurück" do
    line = [Text::Span.new("a", Text::Style.new(bold: true)),
            Text::Span.new("b", Text::Style.new(dim: true))]
    out = Text.to_ansi(line)
    # Ohne Rücksetzen bliebe das Bold über dem zweiten Span stehen.
    out.should contain "\e[0m"
    out.should end_with "\e[0m"
  end

  it "gibt ohne Farbe reinen Text aus" do
    line = [Text::Span.new("a", Text::Style.new(bold: true)), Text::Span.new("b")]
    Text.to_ansi(line, color: false).should eq "ab"
  end

  it "erzeugt für eine ungestylte Zeile keine Sequenzen" do
    Text.to_ansi(Text.line("schlicht")).should eq "schlicht"
  end
end

describe "Anvil::Text::Style#plain?" do
  it "ist nur wahr, wenn wirklich nichts gesetzt ist" do
    Text::Style::NONE.plain?.should be_true
    Text::Style.new(fg: Text::Palette::INFO).plain?.should be_false
  end

  it "erkennt auch reine Attribute als nicht schlicht" do
    # `Attribute` ist ein @[Flags]-Enum mit None = 0; dessen `none?`-Prädikat
    # ist bei jedem Wert wahr. Wer es benutzt, hält jeden Stil für schlicht.
    Text::Style.new(bold: true).plain?.should be_false
    Text::Style.new(dim: true).plain?.should be_false
    Text::Style.new(reverse: true).plain?.should be_false
  end
end

describe "Anvil::Text.wrap Randfälle" do
  it "behandelt eingebettete Zeilenumbrüche als Umbruch" do
    # Sonst landete das Steuerzeichen in einer Zelle.
    lines = Text.wrap(Text.line("a\nb"), 20)
    lines.map { |l| Text.plain(l) }.should eq ["a", "b"]
  end

  it "trennt Umbrüche auch über Span-Grenzen und behält die Stile" do
    bold = Text::Style.new(bold: true)
    line = [Text::Span.new("a\nb", bold), Text::Span.new("c")]
    lines = Text.wrap(line, 20)
    lines.map { |l| Text.plain(l) }.should eq ["a", "bc"]
    lines[1].first.style.bold?.should be_true
  end

  it "erhält Leerzeilen" do
    Text.wrap(Text.line("a\n\nb"), 20).map { |l| Text.plain(l) }.should eq ["a", "", "b"]
  end

  it "wirft CR aus CRLF weg" do
    Text.wrap(Text.line("a\r\nb"), 20).map { |l| Text.plain(l) }.should eq ["a", "b"]
  end

  it "klemmt eine nicht-positive Breite auf eine Spalte, statt Inhalt zu verlieren" do
    # Ein Fenster kann während einer Größenänderung kurz 0 Spalten melden.
    Text.wrap(Text.line("ab"), 0).map { |l| Text.plain(l) }.should eq ["a", "b"]
    Text.wrap(Text.line("ab"), -5).map { |l| Text.plain(l) }.should eq ["a", "b"]
  end
end
