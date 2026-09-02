require "../surface"

module Anvil
  # Alternate screen: the app owns the whole grid, nothing reaches the
  # scrollback. For animation and full-screen tools.
  #
  # Thin, because termisu already does everything here — cell buffer, diff,
  # synchronized output. The class exists so the layers above need not know
  # which mode they are running in.
  class Surface::Fullscreen < Surface
    getter backend : Backend

    def initialize(@backend : Backend = Backend.new(alternate_screen: true))
      raise ArgumentError.new("Fullscreen needs a backend in the alternate screen") unless @backend.alternate_screen?
      @terminal = @backend.terminal
      @terminal.write("\e[?25l")
      @terminal.flush
    end

    def size : {Int32, Int32}
      @terminal.size
    end

    def put_cell(x : Int32, y : Int32, grapheme : String, style : Text::Style) : Nil
      @terminal.set_cell(x, y, grapheme, style.resolved_fg, style.resolved_bg, style.attr)
    end

    def begin_frame : Nil
    end

    def end_frame : Nil
      @terminal.render
    end

    def invalidate! : Nil
      @terminal.sync
    end

    def close : Nil
      @backend.close
    end
  end
end
