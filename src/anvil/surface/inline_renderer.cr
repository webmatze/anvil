require "termisu"
require "../text"

module Anvil
  # Ein `IO`, das Schreibvorgänge in ein `Termisu::Terminal` leitet.
  #
  # Damit spricht der Renderer schlicht `IO`, während die Ausgabe im Betrieb
  # trotzdem durch denselben Weg geht wie termisus eigene Sequenzen — kein
  # zweiter Puffer, der sich mit dem ersten verschränken könnte.
  class TerminalIO < IO
    def initialize(@terminal : Termisu::Terminal)
    end

    def read(slice : Bytes) : Int32
      raise IO::Error.new("TerminalIO schreibt nur")
    end

    def write(slice : Bytes) : Nil
      @terminal.write(slice)
    end

    def flush : Nil
      @terminal.flush
    end
  end

  # Übersetzt die absoluten Pufferkoordinaten, die `Termisu::Buffer#render_to`
  # liefert, in Bewegungen innerhalb einer Region, deren obere Kante irgendwo
  # im Scrollback steht.
  #
  # Vertikal muss relativ adressiert werden (CUU/CUD): die absolute
  # Bildschirmzeile der Region ist unbekannt und ändert sich bei jedem Scroll.
  # Horizontal geht absolut (CHA) — die Region beginnt immer in Spalte 0 und
  # ist so breit wie das Terminal, das spart die gesamte Spaltenbuchhaltung.
  #
  # Schreibt in ein `IO`, nicht in ein Terminal: so lässt sich eine Region in
  # einen Speicherpuffer rendern und prüfen, ohne ein echtes Terminal zu
  # brauchen.
  class InlineRenderer < Termisu::Renderer
    # Wo der Cursor steht, in Regionszeilen ab 0. Die Surface hält ihn
    # zwischen den Frames auf Zeile 0.
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

    # --- Stil ---------------------------------------------------------------
    #
    # Der Puffer meldet Stilwechsel über `apply_sgr`; die granularen Setzer
    # darunter sind die Rückfallebene der Renderer-Schnittstelle und werden
    # auf denselben Weg gebracht, damit der zwischengespeicherte Zustand
    # stimmt.

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

    # Eine einzelne kombinierte SGR-Sequenz je Wechsel statt einer pro
    # Eigenschaft. Werden Attribute *abgewählt*, muss zurückgesetzt und alles
    # neu gesetzt werden — dafür gibt es keine Teilrücknahme, die überall
    # zuverlässig wäre.
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
