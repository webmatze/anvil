require "../surface"
require "./inline_renderer"

module Anvil
  # A live region at the bottom of the normal scrollback.
  #
  # Finished content is written to the scrollback once and never touched again;
  # only the region below it is redrawn. The transcript therefore stays
  # copyable and searchable — the model smith and Claude Code use.
  #
  # Drawing goes through `Termisu::Buffer`, so the region inherits its cell
  # diff, SGR coalescing and wide-character handling.
  class Surface::Inline < Surface
    getter backend : Backend?
    getter height : Int32
    getter io : IO

    def initialize(backend : Backend = Backend.new(alternate_screen: false), height : Int32 = 1)
      raise ArgumentError.new("Inline must not run in the alternate screen") if backend.alternate_screen?
      @backend = backend
      width, screen_height = backend.size
      @io = TerminalIO.new(backend.terminal)
      @width = width
      @screen_height = screen_height
      @height = height
      @buffer = Termisu::Buffer.new(@width, height)
      @renderer = InlineRenderer.new(@io, @width, height)
      @cursor_target = nil.as({Int32, Int32}?)

      start(height)
    end

    # Without a terminal: the region renders into any `IO`.
    #
    # That makes it possible to inspect what would actually go out without a
    # real terminal — and lets an application render its interface into a file,
    # for approval snapshots or bug reports.
    def self.memory(io : IO, width : Int32, screen_height : Int32, height : Int32 = 1) : Inline
      new(io, width, screen_height, height)
    end

    protected def initialize(@io : IO, @width : Int32, @screen_height : Int32, height : Int32)
      @backend = nil
      @height = height
      @buffer = Termisu::Buffer.new(@width, height)
      @renderer = InlineRenderer.new(@io, @width, height)
      @cursor_target = nil.as({Int32, Int32}?)

      start(height)
    end

    private def start(height : Int32) : Nil
      @io << "\e[?25l"
      claim_rows(height)
      @io.flush
    end

    def size : {Int32, Int32}
      {@width, @height}
    end

    # The region is redrawn in place, and that only works while it fits on the
    # screen: `cursor_up` stops at the top row, so a taller region could never
    # be walked back over — every redraw would push another copy into the
    # scrollback instead. One row stays free to give the commit path room.
    def max_height : Int32
      {@screen_height - 1, 1}.max
    end

    def put_cell(x : Int32, y : Int32, grapheme : String, style : Text::Style) : Nil
      @buffer.set_cell(x, y, grapheme, style.resolved_fg, style.resolved_bg, style.attr)
    end

    def begin_frame : Nil
    end

    def end_frame : Nil
      @io << "\e[?2026h"
      @buffer.render_to(@renderer, auto_flush: false)
      if target = @cursor_target
        @renderer.move_to_row(target[1])
        @io << "\e[#{target[0] + 1}G\e[?25h"
      else
        park
        @io << "\e[?25l"
      end
      @io << "\e[?2026l"
      @io.flush
      # The cursor may now sit somewhere other than row 0; the next
      # `end_frame` moves relative to that, and `row` tracks it correctly.
    end

    # A visible cursor at this spot in the region — for the input line.
    def cursor_at(x : Int32, y : Int32) : Nil
      @cursor_target = {x, y}
    end

    # No visible cursor (the normal case while nothing is being typed).
    def hide_cursor : Nil
      @cursor_target = nil
    end

    def invalidate! : Nil
      @buffer.invalidate
    end

    def clear_screen : Nil
      @io << "\e[2J\e[H"
      @renderer.row = 0
      @buffer.invalidate
    end

    # Change the height. Growing asks the terminal for rows (it scrolls);
    # shrinking erases the surplus ones. Either way what is on screen has
    # shifted afterwards, so it is invalid.
    def height=(new_height : Int32) : Nil
      return if new_height == @height
      raise ArgumentError.new("height must be >= 1") if new_height < 1
      new_height = max_height if new_height > max_height
      return if new_height == @height

      if new_height > @height
        move_to(@height - 1)
        (new_height - @height).times { @io << ("\r\n") }
        @renderer.row = new_height - 1
      else
        (new_height...@height).each do |y|
          move_to(y)
          @io << "\e[2K"
        end
      end

      @height = new_height
      @renderer.height = new_height
      @buffer.resize(@width, new_height)
      @buffer.invalidate
      park
      @io.flush
    end

    # Reacts to the window changing size.
    def resized! : Nil
      backend = @backend
      return unless backend
      width, screen_height = backend.terminal.query_size
      @screen_height = screen_height
      return if width == @width
      @width = width
      @renderer.width = width
      @buffer.resize(@width, @height)
      @buffer.invalidate
    end

    # For running without a terminal: set the size from outside.
    def resize(width : Int32, screen_height : Int32) : Nil
      @screen_height = screen_height
      return if width == @width
      @width = width
      @renderer.width = width
      @buffer.resize(@width, @height)
      @buffer.invalidate
    end

    # Writes lines permanently into the scrollback, above the region.
    def commit(lines : Array(Text::StyledLine)) : Nil
      return if lines.empty?
      move_to(0)
      @io << ("\e[0J") # wipe the region: from the cursor to end of screen
      lines.each do |line|
        @io << render_to_ansi(line)
        @io << "\e[0m\r\n"
      end
      # The cursor now sits on the first row of the new region — and that
      # region starts as small as it can.
      #
      # Asking for the old height again here would be wrong: the block just
      # committed has left the region, so it gets smaller. One would push the
      # screen up by the difference and leave the freed rows standing as a gap
      # below the region. How tall it really has to be is known only to the
      # next frame; `height=` then grows by exactly the rows needed.
      @renderer.row = 0
      @height = 1
      @renderer.height = 1
      @buffer.resize(@width, 1)
      @buffer.invalidate
      @io.flush
    end

    def close : Nil
      move_to(0)
      @io << "\e[0J\e[0m\e[?25h"
      @io.flush
      @backend.try &.close
      # The closing newline is not cosmetic: without it the output ends
      # mid-line and the shell shows its "incomplete line" marker (zsh: `%`)
      # before the prompt. It comes after `backend.close`, because that still
      # writes the restore sequences.
      @io << "\r\n"
      @io.flush
    end

    # Committed lines do not go through the cell buffer — they are written
    # once and never diffed, so an ANSI string is the right shape for them.
    private def render_to_ansi(line : Text::StyledLine) : String
      Text.to_ansi(line)
    end

    # Asks for `n` rows and parks the cursor on the first of them.
    private def claim_rows(n : Int32) : Nil
      return if n <= 1
      (n - 1).times { @io << ("\r\n") }
      @io << "\e[#{n - 1}A"
      @renderer.row = 0
    end

    private def move_to(y : Int32) : Nil
      @renderer.move_to_row(y)
      @io << "\r"
    end

    private def park : Nil
      move_to(0)
    end
  end
end
