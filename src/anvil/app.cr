require "./loop"
require "./view"
require "./surface/inline"
require "./widgets/input_editor"

module Anvil
  # The inline application: block lists, live region, input line and modal
  # questions — the model smith and Claude Code use.
  #
  # Finished blocks move into the scrollback once; the region below is redrawn
  # for as long as something changes.
  class App
    enum State
      Idle      # at the prompt, the editor gets the keys
      Busy      # something is running, the user is watching
      ModalChar # waiting for one of a set of keys
      ModalText # waiting for a line of text
      Done
    end

    getter surface : Surface
    getter editor : Widgets::InputEditor
    getter state : State
    getter blocks : Array(View::Block)

    # The loop — for applications that want a say in the tick.
    getter loop : Loop

    # What the status line looks like is the app's decision — all that is
    # settled here is that there is one and that it is never trimmed away.
    property status : Proc(Int32, Text::StyledLine)?
    property prompt : Text::StyledLine

    # Popup lines above the input, when the app has one open.
    property popup : Proc(Int32, Array(Text::StyledLine))?

    # What happens to a submitted line. `run` sets it from its block; set
    # directly, the app can also be driven without the loop.
    property on_submit : Proc(String, Nil)?

    # Sees every key before the state machine. When the hook returns `true`
    # the key counts as consumed and the app does not touch it.
    #
    # It exists so an application can keep key meanings only it knows — an open
    # popup claiming the arrow keys, or a Ctrl-C that clears the input first
    # and quits second.
    property on_key : Proc(Termisu::Event::Key, Bool)?

    # After a resize has settled, once the surface has been updated and
    # invalidated. Whether the whole screen should be wiped on top of that is
    # something only the application knows: the terminal has reflowed the
    # scrollback, and whether that is tolerable depends on what is in it.
    # The wording of the marker standing in for trimmed lines.
    property hidden_marker : Proc(Int32, Text::StyledLine)?

    property on_resize : Proc(Nil)?

    property on_interrupt : Proc(Nil)?
    property on_abort : Proc(Nil)?

    DOUBLE_INTERRUPT_WINDOW = 1.second

    def initialize(@surface : Surface, @loop : Loop, *,
                   history : Array(String) = Array(String).new)
      @editor = Widgets::InputEditor.new(history)
      @state = State::Idle
      @blocks = Array(View::Block).new
      @committed = 0
      @prompt = Text.line("> ", Text::Style.new(fg: Text::Palette::ACCENT, bold: true))

      @char_channel = nil.as(Channel(Char)?)
      @text_channel = nil.as(Channel(String)?)
      @modal_keys = Array(Char).new
      @modal_cancel = nil.as(Char?)
      @modal_header = Text::EMPTY_LINE
      @modal_body = Array(Text::StyledLine).new
      @modal_prompt = Text::EMPTY_LINE

      @interrupts = 0
      @last_interrupt = Time.instant
    end

    # --- content --------------------------------------------------------------

    def add_block(block : View::Block) : View::Block
      @blocks << block
      mark_dirty
      block
    end

    def notice(text : String, style : Text::Style = Text::Style.new(fg: Text::Palette::INFO)) : Nil
      add_block(View::TextBlock.new(text, style))
    end

    def notice(lines : Array(Text::StyledLine)) : Nil
      add_block(View::TextBlock.new(lines))
    end

    def mark_dirty : Nil
      @loop.mark_dirty
    end

    # Clear everything: blocks are dropped, the screen is wiped. For an
    # explicit "start over" from the application.
    def clear! : Nil
      @blocks.clear
      @committed = 0
      @surface.clear_screen
      @surface.invalidate!
      mark_dirty
    end

    def busy! : Nil
      self.state = State::Busy
      mark_dirty
    end

    # To be called from the fiber that did the work: the prompt comes back.
    def idle! : Nil
      self.state = State::Idle if @state.busy?
      mark_dirty
    end

    def quit : Nil
      self.state = State::Done
      @loop.stop
    end

    # --- modal questions ------------------------------------------------------

    # Blocks the *calling* fiber until the user presses one of the keys. The
    # key loop keeps running meanwhile — without that there would be no tool
    # approval in the middle of a running turn.
    #
    # `cancel` says what Escape and Ctrl-C are answered with. Without it a
    # question could only be left by one of the keys offered — and "cancel" is
    # the expectation for a prompt, not the exception.
    def ask(header : Text::StyledLine, body : Array(Text::StyledLine),
            keys : Array(Char), hint : Text::StyledLine, cancel : Char? = nil) : Char
      channel = Channel(Char).new(1)
      @char_channel = channel
      @modal_cancel = cancel
      @modal_keys = keys
      @modal_header = header
      @modal_body = body
      @modal_prompt = hint
      self.state = State::ModalChar
      mark_dirty

      answer = channel.receive
      clear_modal
      answer
    end

    # The same for a line of text (plan feedback, a free-form answer).
    def ask_text(header : Text::StyledLine, body : Array(Text::StyledLine)) : String
      channel = Channel(String).new(1)
      @text_channel = channel
      @modal_header = header
      @modal_body = body
      @modal_prompt = @prompt
      self.state = State::ModalText
      @editor.reset
      mark_dirty

      answer = channel.receive
      clear_modal
      answer
    end

    # Like `ask`, but with a key loop of its own — for questions that must be
    # answered before `run` even starts (a trust prompt at startup). It blocks
    # the calling fiber without the main loop running.
    def ask_sync(header : Text::StyledLine, body : Array(Text::StyledLine),
                 keys : Array(Char), hint : Text::StyledLine, cancel : Char? = nil) : Char
      saved = {@state, @modal_header, @modal_body, @modal_prompt, @modal_keys, @modal_cancel}
      @modal_cancel = cancel

      @modal_header = header
      @modal_body = body
      @modal_prompt = hint
      @modal_keys = keys
      self.state = State::ModalChar
      render

      answer = cancel || ' '
      until @loop.closed?
        event = @loop.poll(50.milliseconds)
        next unless event.is_a?(Termisu::Event::Key)
        if ch = answer_key(event)
          answer = ch
          break
        end
      end

      restored, @modal_header, @modal_body, @modal_prompt, @modal_keys, @modal_cancel = saved
      self.state = restored
      render
      answer
    end

    # While anything is in flight, drawing continues: spinners and elapsed
    # times move on their own without anyone reporting them dirty. While idle a
    # frame costs nothing, because none is drawn.
    private def state=(value : State) : Nil
      @state = value
      @loop.animating = !value.idle?
    end

    def modal_open? : Bool
      @state.modal_char? || @state.modal_text?
    end

    # Resolve open questions on shutdown. A fiber waiting on an `ask` while
    # the loop ends would otherwise never return.
    private def release_waiters : Nil
      if channel = @char_channel
        @char_channel = nil
        channel.send(@modal_cancel || ' ')
      end
      if channel = @text_channel
        @text_channel = nil
        channel.send("")
      end
    end

    private def clear_modal : Nil
      @char_channel = nil
      @text_channel = nil
      @modal_cancel = nil
      @modal_header = Text::EMPTY_LINE
      @modal_body = Array(Text::StyledLine).new
      @modal_prompt = Text::EMPTY_LINE
      self.state = State::Busy
      mark_dirty
    end

    # --- the loop -------------------------------------------------------------

    def run(&handler : String -> Nil) : Nil
      @on_submit = handler
      @loop.on_event { |event| handle_event(event) }
      @loop.on_draw { render }
      @loop.on_resize do
        @surface.resized!
        @surface.invalidate!
        @on_resize.try &.call
      end
      begin
        @loop.run
      ensure
        release_waiters
        @surface.close
      end
    end

    # Public so that tests (and embeddings) can feed events without needing a
    # terminal.
    def handle_event(event : Termisu::Event::Any) : Nil
      return unless event.is_a?(Termisu::Event::Key)

      if filter = @on_key
        if filter.call(event)
          mark_dirty
          return
        end
      end

      # Above the state machine, because a garbled screen is likeliest
      # mid-turn or under a modal — exactly the two states that would
      # otherwise swallow the key.
      if event.ctrl? && event.key.to_char == 'l'
        redraw_all!
        return
      end

      if event.ctrl_c?
        interrupt
        return
      end

      case @state
      when State::Idle      then idle_key(event)
      when State::Busy      then nil
      when State::ModalChar then modal_char_key(event)
      when State::ModalText then modal_text_key(event)
      end
      mark_dirty
    end

    private def idle_key(event : Termisu::Event::Key) : Nil
      if submitted = @editor.handle(event)
        return if submitted.strip.empty?
        busy!
        # On a fiber of its own so the key loop keeps running: only that way
        # can the work ask a modal question on the way.
        callback = @on_submit
        spawn do
          callback.try &.call(submitted)
        end
      end
    end

    private def modal_char_key(event : Termisu::Event::Key) : Nil
      channel = @char_channel
      return unless channel
      if ch = answer_key(event)
        channel.send(ch)
      end
    end

    # The letter of an answer key, or nil when the key is not among the
    # choices. `char` is set for ordinary characters; the key enum covers the
    # cases where the parser supplies none.
    private def answer_key(event : Termisu::Event::Key) : Char?
      if cancel = @modal_cancel
        return cancel if event.key.escape? || event.ctrl_c?
      end
      ch = event.char || event.key.to_char
      return nil unless ch
      down = ch.downcase
      @modal_keys.includes?(down) ? down : nil
    end

    private def modal_text_key(event : Termisu::Event::Key) : Nil
      channel = @text_channel
      return unless channel
      if answer = @editor.handle(event)
        channel.send(answer)
      end
    end

    # One Ctrl-C asks to stop, a second one shortly after quits.
    private def interrupt : Nil
      now = Time.instant
      @interrupts = (now - @last_interrupt) < DOUBLE_INTERRUPT_WINDOW ? @interrupts + 1 : 1
      @last_interrupt = now

      if @interrupts >= 2
        @on_abort.try &.call
        quit
      else
        @on_interrupt.try &.call
        mark_dirty
      end
    end

    # --- drawing --------------------------------------------------------------

    # Write finished blocks into the scrollback once; after that they are never
    # touched again.
    private def commit_finished : Nil
      width = @surface.width
      pending = Array(Text::StyledLine).new
      while @committed < @blocks.size && @blocks[@committed].finalized?
        pending << Text::EMPTY_LINE.dup unless @committed == 0 && pending.empty?
        pending.concat(@blocks[@committed].lines(width))
        @committed += 1
      end
      @surface.commit(pending) unless pending.empty?
    end

    # Builds the live region and draws it. Public for the same reason.
    def render : Nil
      commit_finished

      width = @surface.width
      lines = View::Region.compose(segments(width), @surface.max_height, @hidden_marker)

      @surface.height = lines.size
      lines.each_with_index { |line, y| @surface.put_line(0, y, line) }
      place_cursor(lines.size)
      @surface.end_frame
    end

    private def segments(width : Int32) : Array(View::Segment)
      out = Array(View::Segment).new

      # Blocks still running: they stay in the region until they are done.
      if @committed < @blocks.size
        live = Array(Text::StyledLine).new
        (@committed...@blocks.size).each_with_index do |i, n|
          live << Text::EMPTY_LINE.dup if n > 0
          live.concat(@blocks[i].lines(width))
        end
        out << View::Segment.droppable(live)
      end

      if modal_open?
        # The question stays; the text it describes may give way.
        out << View::Segment.pinned([@modal_header]) unless @modal_header.empty?
        out << View::Segment.droppable(@modal_body) unless @modal_body.empty?
        unless @modal_prompt.empty?
          out << View::Segment.droppable([Text::EMPTY_LINE.dup])
          out << View::Segment.pinned([modal_prompt_line(width)])
        end
      end

      out << View::Segment.droppable([Text::EMPTY_LINE.dup]) unless out.empty?

      if popup_proc = @popup
        popup_lines = popup_proc.call(width)
        out << View::Segment.droppable(popup_lines) unless popup_lines.empty?
      end

      tail = Array(Text::StyledLine).new
      if status_proc = @status
        tail << status_proc.call(width)
      end
      tail << input_line(width) if @state.idle?
      out << View::Segment.pinned(tail) unless tail.empty?

      out
    end

    private def input_line(width : Int32) : Text::StyledLine
      field = width - Text.width(@prompt)
      line, _ = @editor.view(field < 1 ? 1 : field)
      @prompt + line
    end

    private def modal_prompt_line(width : Int32) : Text::StyledLine
      return @modal_prompt unless @state.modal_text?
      field = width - Text.width(@modal_prompt)
      line, _ = @editor.view(field < 1 ? 1 : field)
      @modal_prompt + line
    end

    # The cursor belongs in the input line when there is one — otherwise it
    # goes away.
    private def place_cursor(height : Int32) : Nil
      unless @state.idle? || @state.modal_text?
        @surface.hide_cursor
        return
      end

      prefix = @state.modal_text? ? @modal_prompt : @prompt
      field = @surface.width - Text.width(prefix)
      _, col = @editor.view(field < 1 ? 1 : field)
      @surface.cursor_at(Text.width(prefix) + col, height - 1)
    end

    # Wipe the screen and re-emit the whole transcript.
    #
    # Resetting the commit counter is the point: without it, only the live
    # region would remain after the wipe and everything already committed would
    # be gone from the picture. Needed on Ctrl-L (something wrote past us) and
    # after a resize (the terminal reflowed the scrollback).
    def redraw_all! : Nil
      @surface.clear_screen
      @committed = 0
      @surface.invalidate!
      mark_dirty
    end
  end
end
