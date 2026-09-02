require "./spec_helper"

include Anvil
include KeyFactory

private def editor(history = [] of String)
  Widgets::InputEditor.new(history)
end

describe Anvil::Widgets::InputEditor do
  it "nimmt Text auf und meldet ihn beim Absenden" do
    e = editor
    type(e, "hallo")
    e.text.should eq "hallo"
    e.handle(special(Termisu::Input::Key::Enter)).should eq "hallo"
    e.text.should eq ""
  end

  it "fügt an der Cursorposition ein, nicht am Ende" do
    e = editor
    type(e, "hllo")
    3.times { e.handle(special(Termisu::Input::Key::Left)) }
    type(e, "a")
    e.text.should eq "hallo"
  end

  it "löscht rückwärts und vorwärts" do
    e = editor
    type(e, "abc")
    e.handle(special(Termisu::Input::Key::Backspace))
    e.text.should eq "ab"
    e.handle(special(Termisu::Input::Key::Left))
    e.handle(special(Termisu::Input::Key::Delete))
    e.text.should eq "a"
  end

  describe "Ctrl-Tasten" do
    it "a/e springen an Anfang und Ende" do
      e = editor
      type(e, "abc")
      e.handle(ctrl('a'))
      e.cursor.should eq 0
      e.handle(ctrl('e'))
      e.cursor.should eq 3
    end

    it "u löscht bis zum Anfang, k bis zum Ende" do
      e = editor
      type(e, "abcdef")
      3.times { e.handle(special(Termisu::Input::Key::Left)) }
      e.handle(ctrl('u'))
      e.text.should eq "def"
      e.handle(ctrl('e'))
      e.handle(ctrl('u'))
      e.text.should eq ""
    end

    it "w löscht ein Wort rückwärts, samt vorangehender Leerzeichen" do
      e = editor
      type(e, "eins zwei drei")
      e.handle(ctrl('w'))
      e.text.should eq "eins zwei "
      e.handle(ctrl('w'))
      e.text.should eq "eins "
    end
  end

  describe "History" do
    it "holt frühere Eingaben mit hoch und runter zurück" do
      e = editor(["erste", "zweite"])
      e.handle(special(Termisu::Input::Key::Up))
      e.text.should eq "zweite"
      e.handle(special(Termisu::Input::Key::Up))
      e.text.should eq "erste"
      e.handle(special(Termisu::Input::Key::Down))
      e.text.should eq "zweite"
    end

    it "bewahrt den angefangenen Text und bringt ihn zurück" do
      e = editor(["alt"])
      type(e, "angefangen")
      e.handle(special(Termisu::Input::Key::Up))
      e.text.should eq "alt"
      e.handle(special(Termisu::Input::Key::Down))
      e.text.should eq "angefangen"
    end

    it "nimmt Abgesendetes auf, aber keine Wiederholung" do
      e = editor
      type(e, "x")
      e.handle(special(Termisu::Input::Key::Enter))
      type(e, "x")
      e.handle(special(Termisu::Input::Key::Enter))
      e.history.should eq ["x"]
    end

    it "nimmt Leeres nicht auf" do
      e = editor
      type(e, "   ")
      e.handle(special(Termisu::Input::Key::Enter))
      e.history.should be_empty
    end
  end

  describe "Einfügen" do
    it "sendet mitten im Einfügen nicht ab" do
      e = editor
      e.handle(special(Termisu::Input::Key::PasteStart))
      type(e, "eins")
      e.handle(special(Termisu::Input::Key::Enter)).should be_nil
      type(e, "zwei")
      e.handle(special(Termisu::Input::Key::PasteEnd))
      e.text.should eq "eins zwei"
    end

    it "sendet nach dem Einfügen wieder normal ab" do
      e = editor
      e.handle(special(Termisu::Input::Key::PasteStart))
      type(e, "x")
      e.handle(special(Termisu::Input::Key::PasteEnd))
      e.handle(special(Termisu::Input::Key::Enter)).should eq "x"
    end
  end

  describe "Breiten und Cursor" do
    it "rechnet Cursorspalten in Spalten, nicht in Zeichen" do
      e = editor
      type(e, "中文")
      e.columns_before_cursor.should eq 4
      e.handle(special(Termisu::Input::Key::Left))
      e.columns_before_cursor.should eq 2
    end

    it "bewegt sich um ein sichtbares Zeichen, auch bei mehreren Codepoints" do
      e = editor
      e.set_text("é")
      e.cursor.should eq 1
      e.handle(special(Termisu::Input::Key::Backspace))
      e.text.should eq ""
    end

    it "scrollt horizontal und hält den Cursor im Feld" do
      e = editor
      type(e, "abcdefghij")
      line, col = e.view(5)
      # Der Cursor steht hinter dem letzten Zeichen und muss selbst noch ins
      # Feld passen — also bleibt die letzte Spalte für ihn frei.
      Text.plain(line).should eq "ghij"
      col.should eq 4
      col.should be < 5
    end

    it "scrollt zurück, wenn der Cursor nach links wandert" do
      e = editor
      type(e, "abcdefghij")
      8.times { e.handle(special(Termisu::Input::Key::Left)) }
      line, col = e.view(5)
      Text.plain(line).should eq "abcde"
      col.should eq 2
    end

    it "scrollt nicht, solange alles passt" do
      e = editor
      type(e, "abc")
      line, col = e.view(10)
      Text.plain(line).should eq "abc"
      col.should eq 3
    end
  end
end
