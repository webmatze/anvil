require "./spec_helper"

include Anvil
include KeyFactory

private def editor(history = [] of String)
  Widgets::InputEditor.new(history)
end

describe Anvil::Widgets::InputEditor do
  it "collects text and reports it on submit" do
    e = editor
    type(e, "hallo")
    e.text.should eq "hallo"
    e.handle(special(Termisu::Input::Key::Enter)).should eq "hallo"
    e.text.should eq ""
  end

  it "inserts at the cursor, not at the end" do
    e = editor
    type(e, "hllo")
    3.times { e.handle(special(Termisu::Input::Key::Left)) }
    type(e, "a")
    e.text.should eq "hallo"
  end

  it "deletes backwards and forwards" do
    e = editor
    type(e, "abc")
    e.handle(special(Termisu::Input::Key::Backspace))
    e.text.should eq "ab"
    e.handle(special(Termisu::Input::Key::Left))
    e.handle(special(Termisu::Input::Key::Delete))
    e.text.should eq "a"
  end

  describe "Ctrl-Tasten" do
    it "a/e jump to start and end" do
      e = editor
      type(e, "abc")
      e.handle(ctrl('a'))
      e.cursor.should eq 0
      e.handle(ctrl('e'))
      e.cursor.should eq 3
    end

    it "u kills to the start, k to the end" do
      e = editor
      type(e, "abcdef")
      3.times { e.handle(special(Termisu::Input::Key::Left)) }
      e.handle(ctrl('u'))
      e.text.should eq "def"
      e.handle(ctrl('e'))
      e.handle(ctrl('u'))
      e.text.should eq ""
    end

    it "w kills a word backwards, leading spaces included" do
      e = editor
      type(e, "eins zwei drei")
      e.handle(ctrl('w'))
      e.text.should eq "eins zwei "
      e.handle(ctrl('w'))
      e.text.should eq "eins "
    end
  end

  describe "history" do
    it "recalls earlier entries with up and down" do
      e = editor(["erste", "zweite"])
      e.handle(special(Termisu::Input::Key::Up))
      e.text.should eq "zweite"
      e.handle(special(Termisu::Input::Key::Up))
      e.text.should eq "erste"
      e.handle(special(Termisu::Input::Key::Down))
      e.text.should eq "zweite"
    end

    it "keeps the half-typed text and brings it back" do
      e = editor(["alt"])
      type(e, "angefangen")
      e.handle(special(Termisu::Input::Key::Up))
      e.text.should eq "alt"
      e.handle(special(Termisu::Input::Key::Down))
      e.text.should eq "angefangen"
    end

    it "records submissions but not a repeat" do
      e = editor
      type(e, "x")
      e.handle(special(Termisu::Input::Key::Enter))
      type(e, "x")
      e.handle(special(Termisu::Input::Key::Enter))
      e.history.should eq ["x"]
    end

    it "does not record blank input" do
      e = editor
      type(e, "   ")
      e.handle(special(Termisu::Input::Key::Enter))
      e.history.should be_empty
    end
  end

  describe "pasting" do
    it "does not submit in the middle of a paste" do
      e = editor
      e.handle(special(Termisu::Input::Key::PasteStart))
      type(e, "eins")
      e.handle(special(Termisu::Input::Key::Enter)).should be_nil
      type(e, "zwei")
      e.handle(special(Termisu::Input::Key::PasteEnd))
      e.text.should eq "eins zwei"
    end

    it "submits normally again after a paste" do
      e = editor
      e.handle(special(Termisu::Input::Key::PasteStart))
      type(e, "x")
      e.handle(special(Termisu::Input::Key::PasteEnd))
      e.handle(special(Termisu::Input::Key::Enter)).should eq "x"
    end
  end

  describe "widths and cursor" do
    it "counts cursor columns in columns, not characters" do
      e = editor
      type(e, "中文")
      e.columns_before_cursor.should eq 4
      e.handle(special(Termisu::Input::Key::Left))
      e.columns_before_cursor.should eq 2
    end

    it "moves by one visible character even across several codepoints" do
      e = editor
      e.set_text("é")
      e.cursor.should eq 1
      e.handle(special(Termisu::Input::Key::Backspace))
      e.text.should eq ""
    end

    it "scrolls horizontally and keeps the cursor inside the field" do
      e = editor
      type(e, "abcdefghij")
      line, col = e.view(5)
      # The cursor sits past the last character and has to fit into the field
      # itself — so the last column stays free for it.
      Text.plain(line).should eq "ghij"
      col.should eq 4
      col.should be < 5
    end

    it "scrolls back when the cursor moves left" do
      e = editor
      type(e, "abcdefghij")
      8.times { e.handle(special(Termisu::Input::Key::Left)) }
      line, col = e.view(5)
      Text.plain(line).should eq "abcde"
      col.should eq 2
    end

    it "does not scroll while everything fits" do
      e = editor
      type(e, "abc")
      line, col = e.view(10)
      Text.plain(line).should eq "abc"
      col.should eq 3
    end
  end
end
