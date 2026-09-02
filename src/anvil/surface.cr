require "./backend"
require "./text"

module Anvil
  # Die Zeichenfläche — der einzige Ort, an dem sich Fullscreen und Inline
  # unterscheiden. Alles darüber (Blöcke, Editor, Schleife) kennt nur dieses
  # Protokoll.
  abstract class Surface
    abstract def size : {Int32, Int32}
    abstract def put_cell(x : Int32, y : Int32, grapheme : String, style : Text::Style) : Nil
    abstract def begin_frame : Nil
    abstract def end_frame : Nil

    # Erklärt den Bildschirminhalt für ungültig: der nächste Frame wird
    # vollständig neu gezeichnet statt gediffed. Nötig, wenn etwas anderes
    # auf das Terminal geschrieben hat (ein Subprozess) oder der Nutzer
    # Ctrl-L drückt.
    abstract def invalidate! : Nil
    abstract def close : Nil

    def width : Int32
      size[0]
    end

    # --- Fähigkeiten, die nur der Inline-Betrieb wirklich hat ---------------
    #
    # Sie stehen trotzdem hier, mit unschädlichen Vorgaben: so kann dieselbe
    # App-Schicht auf beiden Betriebsarten laufen, statt dass jede Anwendung
    # abfragt, in welcher sie steckt. Im Vollbild gibt es keinen Scrollback,
    # also ist `commit` dort schlicht nichts zu tun.

    # Schreibt Zeilen dauerhaft oberhalb der Zeichenfläche.
    def commit(lines : Array(Text::StyledLine)) : Nil
    end

    # Höhe der Live-Region. Im Vollbild fest.
    def height=(value : Int32) : Nil
    end

    # Wie hoch die Region höchstens werden darf.
    def max_height : Int32
      height
    end

    def cursor_at(x : Int32, y : Int32) : Nil
    end

    def hide_cursor : Nil
    end

    # Nach einer Größenänderung des Fensters.
    def resized! : Nil
    end

    # Vollbild-Löschen — nur für die ausdrückliche Wiederherstellung (Ctrl-L).
    def clear_screen : Nil
    end

    def height : Int32
      size[1]
    end

    def put_cell(x : Int32, y : Int32, char : Char, style : Text::Style) : Nil
      put_cell(x, y, char.to_s, style)
    end

    # Schreibt eine gestylte Zeile ab Spalte `x`. Gibt zurück, wie viele
    # Spalten belegt wurden.
    #
    # Liegt hier statt in den Implementierungen, weil beide Betriebsarten
    # dasselbe meinen: Grapheme für Grapheme in Zellen, mit korrekter Breite
    # für CJK und Emoji. Nur das Setzen einer Zelle unterscheidet sie.
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

    # Wie `put`, füllt den Zeilenrest aber mit Leerzeichen. Ohne das bleiben
    # Reste des vorigen Frames stehen, wo die neue Zeile kürzer ist.
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
