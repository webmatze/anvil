require "../surface"
require "./inline_renderer"

module Anvil
  # Live-Region am unteren Rand des normalen Scrollbacks.
  #
  # Fertige Inhalte werden einmal in den Scrollback geschrieben und danach nie
  # wieder angefasst; nur die Region darunter wird neu gezeichnet. Das
  # Transcript bleibt damit kopier- und durchsuchbar — das Modell von smith
  # und Claude Code.
  #
  # Gezeichnet wird über `Termisu::Buffer`, die Region erbt also dessen
  # Cell-Diff, SGR-Coalescing und Wide-Char-Logik.
  class Surface::Inline < Surface
    getter backend : Backend?
    getter height : Int32
    getter io : IO

    def initialize(backend : Backend = Backend.new(alternate_screen: false), height : Int32 = 1)
      raise ArgumentError.new("Inline darf nicht im Alternate Screen laufen") if backend.alternate_screen?
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

    # Ohne Terminal: die Region rendert in ein beliebiges `IO`.
    #
    # Damit lässt sich prüfen, was tatsächlich hinausginge, ohne ein echtes
    # Terminal — und eine Anwendung kann ihre Oberfläche in eine Datei
    # rendern, für Abnahmebilder oder Fehlerberichte.
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

    # Die Region wird an Ort und Stelle neu gezeichnet, und das geht nur,
    # solange sie auf den Bildschirm passt: `cursor_up` stoppt an der
    # obersten Zeile, eine höhere Region ließe sich nie zurücklaufen — jeder
    # Redraw schöbe stattdessen eine weitere Kopie in den Scrollback.
    # Eine Zeile bleibt frei, damit der Committen-Pfad Platz hat.
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
      # Der Cursor steht jetzt evtl. nicht auf Zeile 0; das nächste
      # `end_frame` bewegt ihn relativ von dort, `row` ist korrekt geführt.
    end

    # Sichtbarer Cursor an dieser Stelle der Region — für die Eingabezeile.
    def cursor_at(x : Int32, y : Int32) : Nil
      @cursor_target = {x, y}
    end

    # Kein sichtbarer Cursor (der Normalfall, solange nichts eingegeben wird).
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

    # Höhe ändern. Wächst die Region, werden Zeilen vom Terminal angefordert
    # (es scrollt); schrumpft sie, werden die überzähligen gelöscht. Danach
    # ist der Bildschirminhalt in jedem Fall verschoben, also ungültig.
    def height=(new_height : Int32) : Nil
      return if new_height == @height
      raise ArgumentError.new("Höhe muss >= 1 sein") if new_height < 1
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

    # Reagiert auf eine Größenänderung des Fensters.
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

    # Für den Betrieb ohne Terminal: die Größe von außen setzen.
    def resize(width : Int32, screen_height : Int32) : Nil
      @screen_height = screen_height
      return if width == @width
      @width = width
      @renderer.width = width
      @buffer.resize(@width, @height)
      @buffer.invalidate
    end

    # Schreibt Zeilen dauerhaft in den Scrollback, oberhalb der Region.
    def commit(lines : Array(Text::StyledLine)) : Nil
      return if lines.empty?
      move_to(0)
      @io << ("\e[0J") # Region wegwischen: ab Cursor bis Bildschirmende
      lines.each do |line|
        @io << render_to_ansi(line)
        @io << "\e[0m\r\n"
      end
      # Der Cursor steht jetzt auf der ersten Zeile der neuen Region — und
      # die beginnt so klein wie möglich.
      #
      # Die alte Höhe hier wieder anzufordern wäre falsch: der committete
      # Block hat die Region gerade verlassen, sie wird also kleiner. Man
      # schöbe den Bildschirm um die Differenz zu weit hoch und ließe die
      # freigewordenen Zeilen als Lücke unter der Region stehen. Wie hoch sie
      # wirklich sein muss, weiß erst der nächste Frame; `height=` wächst
      # dann um genau so viele Zeilen, wie gebraucht werden.
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
      # Der abschließende Umbruch ist nicht Kosmetik: ohne ihn endet die
      # Ausgabe mitten in einer Zeile, und die Shell zeigt ihre
      # "unvollständige Zeile"-Marke (zsh: `%`) vor dem Prompt. Er kommt nach
      # `backend.close`, weil das noch die Wiederherstellungssequenzen schreibt.
      @io << "\r\n"
      @io.flush
    end

    # Committete Zeilen gehen nicht durch den Zellpuffer — sie werden einmal
    # geschrieben und nie gediffed, also ist eine ANSI-Zeichenkette das
    # richtige Format dafür.
    private def render_to_ansi(line : Text::StyledLine) : String
      Text.to_ansi(line)
    end

    # Fordert `n` Zeilen an und stellt den Cursor auf die erste davon.
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
