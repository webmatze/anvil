require "./spec_helper"

include Anvil
include KeyFactory

private def build_app(width = 40, height = 10)
  surface = Surface::Memory.new(width, height, height)
  # Die Schleife wird in diesen Specs nicht gefahren; Ereignisse gehen direkt
  # an `handle_event`, gezeichnet wird mit `render`.
  loop = Loop.new(->(_t : Time::Span) { nil.as(Termisu::Event::Any?) })
  {App.new(surface, loop), surface}
end

private class DoneBlock < Anvil::View::Block
  def initialize(@text : String)
  end

  def lines(width : Int32) : Array(Anvil::Text::StyledLine)
    [Anvil::Text.line(@text)]
  end
end

private class LiveBlock < Anvil::View::Block
  property text : String
  property? done = false

  def initialize(@text : String)
  end

  def finalized? : Bool
    @done
  end

  def lines(width : Int32) : Array(Anvil::Text::StyledLine)
    [Anvil::Text.line(@text)]
  end
end

describe Anvil::App do
  it "zeichnet Statuszeile und Eingabe" do
    app, surface = build_app
    app.status = ->(w : Int32) { Text.line("bereit") }
    type(app.editor, "hallo")
    app.render
    surface.to_lines.last.should eq "> hallo"
    surface.to_lines[-2].should eq "bereit"
  end

  it "schiebt fertige Blöcke in den Scrollback, unfertige nicht" do
    app, surface = build_app
    app.add_block(DoneBlock.new("fertig"))
    live = LiveBlock.new("läuft")
    app.add_block(live)
    app.render

    surface.committed_text.should contain "fertig"
    surface.committed_text.should_not contain "läuft"
    surface.to_lines.any?(&.includes?("läuft")).should be_true
  end

  it "schiebt einen Block genau einmal in den Scrollback" do
    app, surface = build_app
    app.add_block(DoneBlock.new("einmal"))
    app.render
    app.render
    surface.committed_text.count("einmal").should eq 1
  end

  it "commitet einen Block erst, wenn er fertig ist" do
    app, surface = build_app
    live = LiveBlock.new("läuft")
    app.add_block(live)
    app.render
    surface.committed_text.should be_empty

    live.done = true
    app.render
    surface.committed_text.should contain "läuft"
  end

  describe "Eingabe" do
    it "reicht abgesendeten Text weiter und wechselt in Busy" do
      app, _ = build_app
      submitted = [] of String
      app.on_submit = ->(s : String) { submitted << s; nil }
      type(app.editor, "los")
      app.handle_event(special(Termisu::Input::Key::Enter))
      Fiber.yield
      submitted.should eq ["los"]
      app.state.busy?.should be_true
    end

    it "ignoriert leere Eingaben" do
      app, _ = build_app
      submitted = [] of String
      app.on_submit = ->(s : String) { submitted << s; nil }
      type(app.editor, "   ")
      app.handle_event(special(Termisu::Input::Key::Enter))
      Fiber.yield
      submitted.should be_empty
      app.state.idle?.should be_true
    end

    it "nimmt im Zustand Busy keine Tasten für den Editor an" do
      app, _ = build_app
      app.busy!
      type(app, "x")
      app.editor.text.should eq ""
    end
  end

  describe "Modale Abfragen" do
    it "blockiert den fragenden Fiber und läuft weiter, wenn geantwortet wird" do
      app, _ = build_app
      answer = nil.as(Char?)
      spawn do
        answer = app.ask(Text.line("Wirklich?"), [Text.line("Details")], ['j', 'n'], Text.line("[j/n]"))
      end
      Fiber.yield
      app.state.modal_char?.should be_true
      answer.should be_nil

      app.handle_event(char('j'))
      Fiber.yield
      answer.should eq 'j'
      app.state.modal_char?.should be_false
    end

    it "nimmt nur die angebotenen Tasten an" do
      app, _ = build_app
      answer = nil.as(Char?)
      spawn { answer = app.ask(Text.line("?"), [] of Text::StyledLine, ['j', 'n'], Text.line("[j/n]")) }
      Fiber.yield
      app.handle_event(char('x'))
      Fiber.yield
      answer.should be_nil
      app.handle_event(char('n'))
      Fiber.yield
      answer.should eq 'n'
    end

    it "sammelt eine Zeile Text ein" do
      app, _ = build_app
      answer = nil.as(String?)
      spawn { answer = app.ask_text(Text.line("Warum?"), [] of Text::StyledLine) }
      Fiber.yield
      app.state.modal_text?.should be_true
      type(app, "weil")
      app.handle_event(special(Termisu::Input::Key::Enter))
      Fiber.yield
      answer.should eq "weil"
    end

    it "zeigt die Frage auch dann, wenn der Platz nicht reicht" do
      # Angeheftet: der Text den sie beschreibt weicht, die Frage nie.
      app, surface = build_app(40, 6)
      spawn do
        app.ask(Text.line("Wirklich?"),
          (1..20).map { |i| Text.line("Detail #{i}") },
          ['j'], Text.line("[j]"))
      end
      Fiber.yield
      app.render
      lines = surface.to_lines
      lines.any?(&.includes?("Wirklich?")).should be_true
      lines.any?(&.includes?("[j]")).should be_true
      lines.any?(&.includes?("more lines above")).should be_true
    end
  end

  describe "Ctrl-C" do
    it "bittet beim ersten Mal um Abbruch" do
      app, _ = build_app
      interrupts = 0
      app.on_interrupt = -> { interrupts += 1; nil }
      app.handle_event(ctrl('c'))
      interrupts.should eq 1
      app.state.done?.should be_false
    end

    it "beendet beim zweiten Mal kurz darauf" do
      app, _ = build_app
      aborted = 0
      app.on_abort = -> { aborted += 1; nil }
      app.handle_event(ctrl('c'))
      app.handle_event(ctrl('c'))
      aborted.should eq 1
      app.state.done?.should be_true
    end
  end

  it "setzt den Cursor in die Eingabezeile und versteckt ihn sonst" do
    app, surface = build_app
    type(app.editor, "abc")
    app.render
    surface.cursor.should_not be_nil
    surface.cursor.not_nil![0].should eq 5 # "> " plus drei Zeichen

    app.busy!
    app.render
    surface.cursor.should be_nil
  end
end

describe "Anvil::App Haken für die Anwendung" do
  it "lässt on_key Tasten vor der Zustandsmaschine abfangen" do
    app, _ = build_app
    seen = [] of Char
    app.on_key = ->(e : Termisu::Event::Key) do
      if (ch = e.char) && ch == 'x'
        seen << ch
        true # verbraucht
      else
        false
      end
    end
    type(app, "axb")
    seen.should eq ['x']
    # Nur das, was der Haken durchgelassen hat, kam beim Editor an.
    app.editor.text.should eq "ab"
  end

  it "übergeht bei verbrauchter Taste auch Ctrl-C" do
    # Eine Anwendung mit eigener Abbruch-Bedeutung muss sie behalten können.
    app, _ = build_app
    aborted = 0
    own = 0
    app.on_abort = -> { aborted += 1; nil }
    app.on_key = ->(e : Termisu::Event::Key) { e.ctrl_c? ? (own += 1; true) : false }
    app.handle_event(ctrl('c'))
    app.handle_event(ctrl('c'))
    own.should eq 2
    aborted.should eq 0
  end

  it "clear! wirft Blöcke weg und löscht den Bildschirm" do
    app, surface = build_app
    app.add_block(DoneBlock.new("weg"))
    app.render
    app.clear!
    app.blocks.should be_empty
    # Nach dem Löschen darf nichts erneut committet werden.
    before = surface.commits.size
    app.render
    surface.commits.size.should eq before
  end

  it "nimmt eine Antworttaste auch ohne char an" do
    # Der Parser gibt bei manchen Tasten nur das Key-Enum mit.
    app, _ = build_app
    answer = nil.as(Char?)
    spawn { answer = app.ask(Text.line("?"), [] of Text::StyledLine, ['j'], Text.line("[j]")) }
    Fiber.yield
    app.handle_event(KeyFactory.key(Termisu::Input::Key::LowerJ))
    Fiber.yield
    answer.should eq 'j'
  end
end

describe "Anvil::App Abbruch einer Frage" do
  it "beantwortet Escape mit dem Abbruchzeichen" do
    app, _ = build_app
    answer = nil.as(Char?)
    spawn { answer = app.ask(Text.line("?"), [] of Text::StyledLine, ['j'], Text.line("[j]"), cancel: 'x') }
    Fiber.yield
    app.handle_event(special(Termisu::Input::Key::Escape))
    Fiber.yield
    answer.should eq 'x'
  end

  it "lässt Escape ohne Abbruchzeichen unbeantwortet" do
    app, _ = build_app
    answer = nil.as(Char?)
    spawn { answer = app.ask(Text.line("?"), [] of Text::StyledLine, ['j'], Text.line("[j]")) }
    Fiber.yield
    app.handle_event(special(Termisu::Input::Key::Escape))
    Fiber.yield
    answer.should be_nil
  end
end

describe "Anvil::App Neuaufbau und Animation" do
  it "gibt beim Neuaufbau den ganzen Verlauf erneut aus" do
    # Ohne das bliebe nach dem Löschen nur die Live-Region stehen und alles
    # bereits Committete wäre vom Bild verschwunden.
    app, surface = build_app
    app.add_block(DoneBlock.new("verlauf"))
    app.render
    surface.committed_text.count("verlauf").should eq 1

    app.redraw_all!
    app.render
    surface.committed_text.count("verlauf").should eq 2
  end

  it "zeichnet durchgehend, solange etwas läuft" do
    # Spinner und Laufzeiten bewegen sich von allein; niemand meldet sie als
    # schmutzig.
    app, _ = build_app
    app.loop.animating?.should be_false
    app.busy!
    app.loop.animating?.should be_true
    app.idle!
    app.loop.animating?.should be_false
  end

  it "zeichnet auch durch, solange eine Frage offen ist" do
    app, _ = build_app
    spawn { app.ask(Text.line("?"), [] of Text::StyledLine, ['j'], Text.line("[j]")) }
    Fiber.yield
    app.loop.animating?.should be_true
  end
end
