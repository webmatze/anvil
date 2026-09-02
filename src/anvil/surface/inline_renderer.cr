require "termisu"
require "../text"

module Anvil
  # An `IO` that funnels writes into a `Termisu::Terminal`.
  #
  # It lets the renderer speak plain `IO` while output in production still goes
  # through the same path as termisu's own sequences — no second buffer that
  # could interleave with the first.
  class TerminalIO < IO
    def initialize(@terminal : Termisu::Terminal)
    end

    def read(slice : Bytes) : Int32
      raise IO::Error.new("TerminalIO is write-only")
    end

    def write(slice : Bytes) : Nil
      @terminal.write(slice)
    end

    def flush : Nil
      @terminal.flush
    end
  end

  # Translates the absolute buffer coordinates `Termisu::Buffer#render_to`
  # hands out into movements inside a region whose top edge sits somewhere in
  # the scrollback.
  #
  # Vertical addressing has to be relative (CUU/CUD): the region's absolute
  # screen row is unknown and changes on every scroll. Horizontal can be
  # absolute (CHA) — the region always starts at column 0 and is as wide as the
  # terminal, which saves all of the column bookkeeping.
  #
  # It writes to an `IO`, not to a terminal: that is what allows a region to be
  # rendered into a memory buffer and inspected without a real terminal.
  class InlineRenderer < Termisu::Renderer
    # Where the cursor stands, in region rows from 0. The surface parks it on
    # row 0 between frames.
    property row : Int32 = 0
    property height : Int32
    property width : Int32

    def initialize(@io : IO, @width : Int32, @height : Int32)
      @fg = nil.as(Termisu::Color?)
      @bg = nil.as(Termisu::Color?)
      @attr = Termisu::Attribute::None
    end

    def size : {Int32, Int32}
      {@width, @height}
    end

    def move_cursor(x : Int32, y : Int32)
      move_to_row(y)
      @io << "\e[" << (x + 1) << "G"
    end

    def move_to_row(y : Int32) : Nil
      if y > @row
        @io << "\e[" << (y - @row) << "B"
      elsif y < @row
        @io << "\e[" << (@row - y) << "A"
      end
      @row = y
    end

    def write(data : String, columns_advanced = 0)
      @io << data
    end

    def write(data : Bytes, columns_advanced = 0)
      @io.write(data)
    end

    def flush
      @io.flush
    end

    def close
    end

    def show_cursor
      @io << "\e[?25h"
    end

    def hide_cursor
      @io << "\e[?25l"
    end

    # --- style --------------------------------------------------------------
    #
    # The buffer reports style changes through `apply_sgr`; the granular
    # setters below are the renderer interface's fallback and are routed the
    # same way, so the cached state stays correct.

    def apply_sgr(fg : Termisu::Color, bg : Termisu::Color, attr : Termisu::Attribute,
                  old_fg : Termisu::Color?, old_bg : Termisu::Color?,
                  old_attr : Termisu::Attribute) : Nil
      emit_style(fg, bg, attr)
    end

    def foreground=(color : Termisu::Color)
      emit_style(color, @bg || Termisu::Color.default, @attr)
    end

    def background=(color : Termisu::Color)
      emit_style(@fg || Termisu::Color.default, color, @attr)
    end

    def reset_attributes
      @io << "\e[0m"
      @fg = nil
      @bg = nil
      @attr = Termisu::Attribute::None
    end

    {% for name, code in {bold: 1, dim: 2, cursive: 3, italic: 3, underline: 4,
                          blink: 5, reverse: 7, hidden: 8, strikethrough: 9} %}
      def enable_{{name.id}}
        @io << "\e[{{code}}m"
        @attr |= Termisu::Attribute::{{name.id.camelcase}}
      end
    {% end %}

    # One combined SGR sequence per change instead of one per property. When
    # attributes are *turned off*, everything has to be reset and re-applied —
    # there is no partial undo for them that is reliable everywhere.
    private def emit_style(fg : Termisu::Color, bg : Termisu::Color,
                           attr : Termisu::Attribute) : Nil
      return if fg == @fg && bg == @bg && attr == @attr

      removed = (@attr.value & ~attr.value) != 0
      parts = [] of String
      parts << "0" if removed

      if removed || attr != @attr
        parts << "1" if attr.bold?
        parts << "2" if attr.dim?
        parts << "3" if attr.italic?
        parts << "4" if attr.underline?
        parts << "5" if attr.blink?
        parts << "7" if attr.reverse?
        parts << "8" if attr.hidden?
        parts << "9" if attr.strikethrough?
      end

      if removed || fg != @fg
        parts << (fg.default? ? "39" : Text.sgr_color(fg, 38))
      end
      if removed || bg != @bg
        parts << (bg.default? ? "49" : Text.sgr_color(bg, 48))
      end

      unless parts.empty?
        @io << "\e[" << parts.join(';') << "m"
      end

      @fg = fg
      @bg = bg
      @attr = attr
    end
  end
end
