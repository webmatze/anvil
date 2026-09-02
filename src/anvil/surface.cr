require "./backend"
require "./text"

module Anvil
  # The drawing surface — the one place where fullscreen and inline differ.
  # Everything above it (blocks, editor, loop) knows only this protocol.
  abstract class Surface
    abstract def size : {Int32, Int32}
    abstract def put_cell(x : Int32, y : Int32, grapheme : String, style : Text::Style) : Nil
    abstract def begin_frame : Nil
    abstract def end_frame : Nil

    # Declares what is on screen invalid: the next frame is drawn in full
    # instead of diffed. Needed when something else wrote to the terminal (a
    # subprocess) or the user pressed Ctrl-L.
    abstract def invalidate! : Nil
    abstract def close : Nil

    def width : Int32
      size[0]
    end

    # --- capabilities only the inline mode really has -----------------------
    #
    # They live here anyway, with harmless defaults, so that the same app layer
    # can run on either mode instead of every application asking which one it
    # is in. Fullscreen has no scrollback, so `commit` there is simply nothing
    # to do.

    # Writes lines permanently above the drawing surface.
    def commit(lines : Array(Text::StyledLine)) : Nil
    end

    # Height of the live region. Fixed in fullscreen.
    def height=(value : Int32) : Nil
    end

    # The tallest the region is allowed to get.
    def max_height : Int32
      height
    end

    def cursor_at(x : Int32, y : Int32) : Nil
    end

    def hide_cursor : Nil
    end

    # After the window changed size.
    def resized! : Nil
    end

    # Full-screen erase — only for an explicit recovery (Ctrl-L).
    def clear_screen : Nil
    end

    def height : Int32
      size[1]
    end

    def put_cell(x : Int32, y : Int32, char : Char, style : Text::Style) : Nil
      put_cell(x, y, char.to_s, style)
    end

    # Writes a styled line starting at column `x`. Returns how many columns
    # were taken.
    #
    # It lives here rather than in the implementations because both modes mean
    # the same thing by it: grapheme by grapheme into cells, with the right
    # width for CJK and emoji. Only setting a single cell differs.
    def put(x : Int32, y : Int32, line : Text::StyledLine) : Int32
      col = x
      w = width
      line.each do |span|
        span.text.each_grapheme do |g|
          gs = g.to_s
          gw = Text.grapheme_width(gs)
          break if col + gw > w
          put_cell(col, y, gs, span.style)
          col += gw
        end
      end
      col - x
    end

    # Like `put`, but fills the rest of the line with spaces. Without it,
    # leftovers of the previous frame stay wherever the new line is shorter.
    def put_line(x : Int32, y : Int32, line : Text::StyledLine,
                 style : Text::Style = Text::Style::NONE) : Nil
      col = x + put(x, y, line)
      while col < width
        put_cell(col, y, " ", style)
        col += 1
      end
    end
  end
end
