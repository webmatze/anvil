require "./spec_helper"

include Anvil
include KeyFactory

private def build_app(width = 40, height = 10)
  surface = Surface::Memory.new(width, height, height)
  # The loop is not run in these specs; events go straight to `handle_event`
  # and drawing happens through `render`.
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
  it "draws the status line and the input" do
    app, surface = build_app
    app.status = ->(w : Int32) { Text.line("bereit") }
    type(app.editor, "hallo")
    app.render
    surface.to_lines.last.should eq "> hallo"
    surface.to_lines[-2].should eq "bereit"
  end

  it "pushes finished blocks into the scrollback, unfinished ones not" do
    app, surface = build_app
    app.add_block(DoneBlock.new("fertig"))
    live = LiveBlock.new("running")
    app.add_block(live)
    app.render

    surface.committed_text.should contain "fertig"
    surface.committed_text.should_not contain "running"
    surface.to_lines.any?(&.includes?("running")).should be_true
  end

  it "pushes a block into the scrollback exactly once" do
    app, surface = build_app
    app.add_block(DoneBlock.new("einmal"))
    app.render
    app.render
    surface.committed_text.count("einmal").should eq 1
  end

  it "commits a block only once it is finished" do
    app, surface = build_app
    live = LiveBlock.new("running")
    app.add_block(live)
    app.render
    surface.committed_text.should be_empty

    live.done = true
    app.render
    surface.committed_text.should contain "running"
  end

  describe "input" do
    it "passes submitted text on and switches to Busy" do
      app, _ = build_app
      submitted = [] of String
      app.on_submit = ->(s : String) { submitted << s; nil }
      type(app.editor, "los")
      app.handle_event(special(Termisu::Input::Key::Enter))
      Fiber.yield
      submitted.should eq ["los"]
      app.state.busy?.should be_true
    end

    it "ignores blank input" do
      app, _ = build_app
      submitted = [] of String
      app.on_submit = ->(s : String) { submitted << s; nil }
      type(app.editor, "   ")
      app.handle_event(special(Termisu::Input::Key::Enter))
      Fiber.yield
      submitted.should be_empty
      app.state.idle?.should be_true
    end

    it "takes no editor keys while Busy" do
      app, _ = build_app
      app.busy!
      type(app, "x")
      app.editor.text.should eq ""
    end
  end

  describe "modal questions" do
    it "blocks the asking fiber and continues once answered" do
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

    it "accepts only the keys it offered" do
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

    it "collects a line of text" do
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

    it "shows the question even when there is not enough room" do
      # Pinned: the text it describes gives way, the question never does.
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
    it "asks to stop the first time" do
      app, _ = build_app
      interrupts = 0
      app.on_interrupt = -> { interrupts += 1; nil }
      app.handle_event(ctrl('c'))
      interrupts.should eq 1
      app.state.done?.should be_false
    end

    it "quits on a quick second press" do
      app, _ = build_app
      aborted = 0
      app.on_abort = -> { aborted += 1; nil }
      app.handle_event(ctrl('c'))
      app.handle_event(ctrl('c'))
      aborted.should eq 1
      app.state.done?.should be_true
    end
  end

  it "puts the cursor in the input line and hides it otherwise" do
    app, surface = build_app
    type(app.editor, "abc")
    app.render
    surface.cursor.should_not be_nil
    surface.cursor.not_nil![0].should eq 5 # "> " plus three characters

    app.busy!
    app.render
    surface.cursor.should be_nil
  end
end

describe "Anvil::App hooks for the application" do
  it "lets on_key intercept keys before the state machine" do
    app, _ = build_app
    seen = [] of Char
    app.on_key = ->(e : Termisu::Event::Key) do
      if (ch = e.char) && ch == 'x'
        seen << ch
        true # consumed
      else
        false
      end
    end
    type(app, "axb")
    seen.should eq ['x']
    # Only what the hook let through reached the editor.
    app.editor.text.should eq "ab"
  end

  it "skips even Ctrl-C when the key was consumed" do
    # An application with its own meaning for it must be able to keep it.
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

  it "clear! drops the blocks and wipes the screen" do
    app, surface = build_app
    app.add_block(DoneBlock.new("weg"))
    app.render
    app.clear!
    app.blocks.should be_empty
    # After the wipe nothing may be committed again.
    before = surface.commits.size
    app.render
    surface.commits.size.should eq before
  end

  it "accepts an answer key even without a char" do
    # For some keys the parser supplies only the key enum.
    app, _ = build_app
    answer = nil.as(Char?)
    spawn { answer = app.ask(Text.line("?"), [] of Text::StyledLine, ['j'], Text.line("[j]")) }
    Fiber.yield
    app.handle_event(KeyFactory.key(Termisu::Input::Key::LowerJ))
    Fiber.yield
    answer.should eq 'j'
  end
end

describe "Anvil::App cancelling a question" do
  it "answers Escape with the cancel character" do
    app, _ = build_app
    answer = nil.as(Char?)
    spawn { answer = app.ask(Text.line("?"), [] of Text::StyledLine, ['j'], Text.line("[j]"), cancel: 'x') }
    Fiber.yield
    app.handle_event(special(Termisu::Input::Key::Escape))
    Fiber.yield
    answer.should eq 'x'
  end

  it "leaves Escape unanswered when no cancel character is given" do
    app, _ = build_app
    answer = nil.as(Char?)
    spawn { answer = app.ask(Text.line("?"), [] of Text::StyledLine, ['j'], Text.line("[j]")) }
    Fiber.yield
    app.handle_event(special(Termisu::Input::Key::Escape))
    Fiber.yield
    answer.should be_nil
  end
end

describe "Anvil::App redraw and animation" do
  it "re-emits the whole transcript on a redraw" do
    # Without it, only the live region would remain after the wipe and
    # everything already committed would be gone from the picture.
    app, surface = build_app
    app.add_block(DoneBlock.new("verlauf"))
    app.render
    surface.committed_text.count("verlauf").should eq 1

    app.redraw_all!
    app.render
    surface.committed_text.count("verlauf").should eq 2
  end

  it "keeps drawing while something is running" do
    # Spinners and elapsed times move on their own; nobody reports them
    # dirty.
    app, _ = build_app
    app.loop.animating?.should be_false
    app.busy!
    app.loop.animating?.should be_true
    app.idle!
    app.loop.animating?.should be_false
  end

  it "keeps drawing while a question is open" do
    app, _ = build_app
    spawn { app.ask(Text.line("?"), [] of Text::StyledLine, ['j'], Text.line("[j]")) }
    Fiber.yield
    app.loop.animating?.should be_true
  end
end
