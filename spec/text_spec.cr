require "spec"
require "../src/anvil/text"

include Anvil

private def plain(lines : Array(Text::StyledLine)) : Array(String)
  lines.map { |l| Text.plain(l) }
end

describe Anvil::Text do
  describe ".width" do
    it "counts ASCII as one column each" do
      Text.width("hallo").should eq 5
    end

    it "counts CJK as two columns" do
      Text.width("中文").should eq 4
    end

    it "counts an emoji as two columns, not as two characters" do
      Text.width("🙂").should eq 2
    end

    it "does not count combining marks" do
      # e + combining acute is one grapheme, one column.
      Text.width("é").should eq 1
    end
  end

  describe ".truncate" do
    it "leaves short lines untouched" do
      line = Text.line("kurz")
      Text.truncate(line, 10).should eq line
    end

    it "cuts to the width" do
      Text.plain(Text.truncate(Text.line("abcdefgh"), 3)).should eq "abc"
    end

    it "reserves room for the ellipsis" do
      Text.plain(Text.truncate(Text.line("abcdefgh"), 5, "…")).should eq "abcd…"
    end

    it "schneidet nie mitten in ein zweispaltiges Zeichen" do
      # At width 3 only one CJK character fits; the second would overhang.
      Text.plain(Text.truncate(Text.line("中文字"), 3)).should eq "中"
    end

    it "cuts across span boundaries and keeps the styles" do
      line = [Text::Span.new("ab", Text::Style.new(bold: true)),
              Text::Span.new("cdef")]
      cut = Text.truncate(line, 3)
      Text.plain(cut).should eq "abc"
      cut.first.style.bold?.should be_true
      cut.last.style.bold?.should be_false
    end
  end

  describe ".wrap" do
    it "leaves fitting lines in one piece" do
      plain(Text.wrap(Text.line("kurz genug"), 20)).should eq ["kurz genug"]
    end

    it "bricht an Wortgrenzen" do
      plain(Text.wrap(Text.line("this is a test"), 7)).should eq ["this is", "a test"]
    end

    it "never produces a line wider than allowed" do
      lines = Text.wrap(Text.line("alpha beta gamma delta epsilon zeta"), 11)
      lines.each { |l| Text.width(l).should be <= 11 }
    end

    it "breaks an over-long word hard instead of overflowing" do
      lines = Text.wrap(Text.line("donaudampfschiff"), 6)
      plain(lines).should eq ["donaud", "ampfsc", "hiff"]
      lines.each { |l| Text.width(l).should be <= 6 }
    end

    it "keeps a word together across a span boundary" do
      # "Hallo" is spread over two spans and must not be split.
      line = [Text::Span.new("Hal", Text::Style.new(bold: true)),
              Text::Span.new("lo Welt")]
      lines = Text.wrap(line, 7)
      plain(lines).should eq ["Hallo", "Welt"]
      # Der Stil des ersten Teils muss erhalten bleiben.
      lines.first.first.style.bold?.should be_true
    end

    it "does not indent continuation lines" do
      plain(Text.wrap(Text.line("aaa   bbb"), 4)).should eq ["aaa", "bbb"]
    end

    it "counts CJK widths rather than characters" do
      lines = Text.wrap(Text.line("中文 字体"), 4)
      lines.each { |l| Text.width(l).should be <= 4 }
      plain(lines).should eq ["中文", "字体"]
    end

    it "merges equally styled graphemes into one span" do
      # Otherwise the renderer would get one batch per character.
      lines = Text.wrap(Text.line("donaudampfschiff"), 6)
      lines.first.size.should eq 1
    end
  end

  describe Anvil::Text::Style do
    it "merge lets the other style win and adds attributes up" do
      a = Text::Style.new(fg: Text::Palette::INFO, bold: true)
      b = Text::Style.new(fg: Text::Palette::ERROR, italic: true)
      m = a.merge(b)
      m.fg.should eq Text::Palette::ERROR
      m.bold?.should be_true
      m.attr.italic?.should be_true
    end

    it "merge keeps what the other one does not set" do
      a = Text::Style.new(fg: Text::Palette::INFO)
      a.merge(Text::Style.new(bold: true)).fg.should eq Text::Palette::INFO
    end
  end
end

describe "Anvil::Text ANSI output" do
  it "emits nothing for an empty style" do
    Text::Style::NONE.ansi.should eq ""
  end

  it "combines attributes and color in one sequence" do
    ansi = Text::Style.new(fg: Text::Color.ansi256(42), bold: true).ansi
    ansi.should start_with "\e["
    ansi.should end_with "m"
    ansi.should contain "1"
    ansi.should contain "38;5;42"
  end

  it "knows true color and the basic colors" do
    Text::Style.new(fg: Text::Color.rgb(1, 2, 3)).ansi.should contain "38;2;1;2;3"
    Text::Style.new(bg: Text::Color.ansi256(7)).ansi.should contain "48;5;7"
  end

  it "resets between two styles" do
    line = [Text::Span.new("a", Text::Style.new(bold: true)),
            Text::Span.new("b", Text::Style.new(dim: true))]
    out = Text.to_ansi(line)
    # Without a reset the bold would carry over the second span.
    out.should contain "\e[0m"
    out.should end_with "\e[0m"
  end

  it "emits plain text with color off" do
    line = [Text::Span.new("a", Text::Style.new(bold: true)), Text::Span.new("b")]
    Text.to_ansi(line, color: false).should eq "ab"
  end

  it "emits no sequences for an unstyled line" do
    Text.to_ansi(Text.line("schlicht")).should eq "schlicht"
  end
end

describe "Anvil::Text::Style#plain?" do
  it "is true only when nothing at all is set" do
    Text::Style::NONE.plain?.should be_true
    Text::Style.new(fg: Text::Palette::INFO).plain?.should be_false
  end

  it "recognises attribute-only styles as not plain" do
    # `Attribute` is a @[Flags] enum with None = 0, whose `none?` predicate is
    # true for every value. Anyone using it thinks every style is plain.
    Text::Style.new(bold: true).plain?.should be_false
    Text::Style.new(dim: true).plain?.should be_false
    Text::Style.new(reverse: true).plain?.should be_false
  end
end

describe "Anvil::Text.wrap edge cases" do
  it "treats embedded newlines as a break" do
    # Otherwise the control character would end up in a cell.
    lines = Text.wrap(Text.line("a\nb"), 20)
    lines.map { |l| Text.plain(l) }.should eq ["a", "b"]
  end

  it "splits on newlines across span boundaries and keeps the styles" do
    bold = Text::Style.new(bold: true)
    line = [Text::Span.new("a\nb", bold), Text::Span.new("c")]
    lines = Text.wrap(line, 20)
    lines.map { |l| Text.plain(l) }.should eq ["a", "bc"]
    lines[1].first.style.bold?.should be_true
  end

  it "preserves blank lines" do
    Text.wrap(Text.line("a\n\nb"), 20).map { |l| Text.plain(l) }.should eq ["a", "", "b"]
  end

  it "drops the CR from CRLF" do
    Text.wrap(Text.line("a\r\nb"), 20).map { |l| Text.plain(l) }.should eq ["a", "b"]
  end

  it "clamps a non-positive width to one column instead of losing content" do
    # A window can briefly report 0 columns during a resize.
    Text.wrap(Text.line("ab"), 0).map { |l| Text.plain(l) }.should eq ["a", "b"]
    Text.wrap(Text.line("ab"), -5).map { |l| Text.plain(l) }.should eq ["a", "b"]
  end
end
