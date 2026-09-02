require "./text"

module Anvil::View
  # Ein Stück Inhalt, das sich auf eine gegebene Breite zeichnen kann.
  #
  # Absichtlich klein gehalten: die Library liefert das Protokoll und den
  # Lebenszyklus, die konkreten Blöcke gehören der App. Ein Werkzeug für
  # LLM-Agenten braucht andere als ein Systemmonitor, und beide sind Domäne.
  abstract class Block
    abstract def lines(width : Int32) : Array(Text::StyledLine)

    # Fertige Blöcke wandern einmal in den Scrollback und werden danach nie
    # wieder gezeichnet. Solange das hier `false` ist, bleibt der Block in
    # der Live-Region und darf sich ändern.
    def finalized? : Bool
      true
    end
  end

  # Ein Block aus fertigen Zeilen — für Hinweise, Banner, alles Statische.
  class TextBlock < Block
    getter source : Array(Text::StyledLine)

    def initialize(@source : Array(Text::StyledLine))
    end

    def self.new(text : String, style : Text::Style = Text::Style::NONE)
      new([Text.line(text, style)])
    end

    def lines(width : Int32) : Array(Text::StyledLine)
      out = Array(Text::StyledLine).new
      @source.each { |l| out.concat(Text.wrap(l, width)) }
      out
    end
  end

  # Ein Abschnitt der Live-Region. `pinned` heißt: darf nie wegfallen.
  #
  # Die Statusleiste und die Eingabezeile sind angeheftet, laufende Blöcke
  # und Popups nicht — auf einem zu kleinen Schirm ist die Eingabe mehr wert
  # als die Liste, die anbietet, sie zu füllen.
  record Segment, lines : Array(Text::StyledLine), pinned : Bool do
    def self.pinned(lines : Array(Text::StyledLine))
      new(lines, true)
    end

    def self.droppable(lines : Array(Text::StyledLine))
      new(lines, false)
    end
  end

  # Setzt die Live-Region aus Abschnitten zusammen und beschneidet sie auf die
  # verfügbare Höhe.
  #
  # Die Region wird an Ort und Stelle neu gezeichnet, was nur funktioniert,
  # solange sie auf den Bildschirm passt (siehe `Surface::Inline#max_height`).
  # Passt sie nicht, fallen nicht-angeheftete Zeilen weg — die ältesten
  # zuerst, hinter einer Marke, die sagt wie viele.
  module Region
    DEFAULT_MARKER_STYLE = Text::Style.new(fg: Text::Palette::MUTED, dim: true)

    # Die Vorgabe für die Marke, die für die weggefallenen Zeilen steht.
    def self.default_marker(hidden : Int32) : Text::StyledLine
      Text.line("⋮ #{hidden} more line#{hidden == 1 ? "" : "s"} above", DEFAULT_MARKER_STYLE)
    end

    # `marker` baut die Zeile, die anstelle des Weggefallenen steht — die
    # Anwendung bestimmt ihren Wortlaut, die Library nur, dass es eine gibt.
    def self.compose(segments : Array(Segment), height : Int32,
                     marker : Proc(Int32, Text::StyledLine)? = nil) : Array(Text::StyledLine)
      budget = height < 1 ? 1 : height
      total = segments.sum { |s| s.lines.size }
      return segments.flat_map(&.lines) if total <= budget

      pinned = segments.sum { |s| s.pinned ? s.lines.size : 0 }
      # Die Marke kostet eine eigene Zeile, und zwar aus dem Platz, den die
      # angehefteten Zeilen übrig lassen.
      room = budget - pinned - 1
      room = 0 if room < 0

      hidden = (total - pinned) - room
      remaining = hidden
      marked = false
      region = Array(Text::StyledLine).new

      segments.each do |segment|
        if segment.pinned || remaining <= 0
          region.concat(segment.lines)
          next
        end

        dropped = {remaining, segment.lines.size}.min
        remaining -= dropped
        unless marked
          region << (marker ? marker.call(hidden) : default_marker(hidden))
          marked = true
        end
        region.concat(segment.lines[dropped..]) if dropped < segment.lines.size
      end

      return region if region.size <= budget

      # Ein Schirm, auf den nicht einmal die angehefteten Zeilen passen. Was
      # überlebt, ist das *untere* Ende — Statusleiste und Eingabe, ohne die
      # der Nutzer nichts tun kann. Beginnt die Region mit einer angehefteten
      # Zeile (der Frage, auf die sich alles bezieht), behält sie ihre Zeile
      # darüber: Tasten, die ein unbenanntes Etwas beantworten, sind weniger
      # wert als die Frage selbst.
      head = (first = segments.first?) && first.pinned && !first.lines.empty? ? [first.lines.first] : Array(Text::StyledLine).new
      head = Array(Text::StyledLine).new if head.size >= budget
      keep = budget - head.size
      head + region[(region.size - keep)..]
    end
  end
end
