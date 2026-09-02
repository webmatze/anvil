require "../surface"

module Anvil
  # Alternate Screen: die App besitzt das ganze Raster, nichts landet im
  # Scrollback. Für Animation und Vollbild-Werkzeuge.
  #
  # Dünn, weil termisu hier schon alles tut — Zellpuffer, Diff, Synchronized
  # Output. Die Klasse existiert, damit die Schichten darüber nicht wissen
  # müssen, in welcher Betriebsart sie laufen.
  class Surface::Fullscreen < Surface
    getter backend : Backend

    def initialize(@backend : Backend = Backend.new(alternate_screen: true))
      raise ArgumentError.new("Fullscreen braucht einen Backend im Alternate Screen") unless @backend.alternate_screen?
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
