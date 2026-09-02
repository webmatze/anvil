require "termisu"

# Styled-Text-Schicht.
#
# termisu ist ein *Zellen*-Puffer: er kennt Zellen, Farben und Breiten, aber
# keine Zeilen, keine Spans und keine Umbrüche. Genau das liegt hier — und es
# ist der Teil, den eine App sonst jedes Mal selbst schreibt.
#
# Breiten kommen aus `Termisu::UnicodeWidth`, damit die Umbruchrechnung
# dieselbe Auffassung von "wie breit ist das" hat wie der Renderer, der es
# später zeichnet. Zwei Quellen dafür wären eine Fehlerquelle: was hier als
# 79 Spalten breit gilt, muss dort in 79 Zellen passen.
module Anvil::Text
  alias Color = Termisu::Color
  alias Attribute = Termisu::Attribute

  # Ein Stil. `nil` bei fg/bg heißt "nicht gesetzt" — das ist der Unterschied
  # zu `Color.default` ("ausdrücklich die Terminal-Vorgabe") und der Grund,
  # warum `merge` überhaupt schichten kann.
  struct Style
    getter fg : Color?
    getter bg : Color?
    getter attr : Attribute

    def initialize(@fg : Color? = nil, @bg : Color? = nil, @attr : Attribute = Attribute::None)
    end

    NONE = Style.new

    def self.new(*, fg : Color? = nil, bg : Color? = nil,
                 bold : Bool = false, dim : Bool = false, italic : Bool = false,
                 underline : Bool = false, reverse : Bool = false,
                 strike : Bool = false, blink : Bool = false)
      attr = Attribute::None
      attr |= Attribute::Bold if bold
      attr |= Attribute::Dim if dim
      attr |= Attribute::Italic if italic
      attr |= Attribute::Underline if underline
      attr |= Attribute::Reverse if reverse
      attr |= Attribute::Strikethrough if strike
      attr |= Attribute::Blink if blink
      new(fg, bg, attr)
    end

    def plain? : Bool
      # Nicht `@attr.none?`: `Attribute` ist ein @[Flags]-Enum mit `None = 0`,
      # und Crystal erzeugt dessen Prädikat als "alle Bits von None gesetzt" —
      # bei einem Nullwert also immer wahr. `Bold.none?` liefert `true`.
      @fg.nil? && @bg.nil? && @attr.value.zero?
    end

    # `other` gewinnt, wo es etwas zu sagen hat; Attribute addieren sich.
    def merge(other : Style) : Style
      Style.new(other.fg || @fg, other.bg || @bg, @attr | other.attr)
    end

    # Prädikat je Attribut. Die einzelnen Member sind ungefährlich — nur
    # `none?` ist bei einem @[Flags]-Enum mit Nullwert immer wahr, siehe
    # `#plain?`.
    {% for name in %w[bold dim italic underline reverse blink hidden strikethrough] %}
      def {{name.id}}? : Bool
        @attr.{{name.id}}?
      end
    {% end %}

    # Der Konstruktor nimmt `strike:`; hier der passende Leser dazu.
    def strike? : Bool
      @attr.strikethrough?
    end

    # Die SGR-Sequenz für diesen Stil, oder "" wenn nichts zu setzen ist.
    #
    # Gebraucht überall dort, wo eine Zeile *einmal* geschrieben und nie
    # gediffed wird: in den Scrollback committete Inhalte, Ausgabe in eine
    # Datei, Abnahmebilder. Der Zellpuffer geht einen anderen Weg.
    def ansi : String
      return "" if plain?

      parts = [] of String
      parts << "1" if @attr.bold?
      parts << "2" if @attr.dim?
      parts << "3" if @attr.italic?
      parts << "4" if @attr.underline?
      parts << "7" if @attr.reverse?
      parts << "9" if @attr.strikethrough?
      if fg = @fg
        parts << Text.sgr_color(fg, 38)
      end
      if bg = @bg
        parts << Text.sgr_color(bg, 48)
      end
      parts.empty? ? "" : "\e[#{parts.join(';')}m"
    end

    # Farben aufgelöst, wie der Renderer sie braucht.
    def resolved_fg : Color
      @fg || Color.default
    end

    def resolved_bg : Color
      @bg || Color.default
    end
  end

  # Ein Textstück mit einheitlichem Stil.
  struct Span
    getter text : String
    getter style : Style

    def initialize(@text : String, @style : Style = Style::NONE)
    end

    def width : Int32
      Text.width(@text)
    end

    def empty? : Bool
      @text.empty?
    end

    def with_text(text : String) : Span
      Span.new(text, @style)
    end
  end

  alias StyledLine = Array(Span)

  EMPTY_LINE = [] of Span

  # Anzeigebreite in Terminalspalten. Grapheme-Cluster, nicht Codepoints:
  # ein Emoji mit Variation Selector ist eine Zelle breit gemeint und zwei
  # Codepoints lang.
  # Breite eines einzelnen Grapheme-Clusters.
  def self.grapheme_width(grapheme : String) : Int32
    Termisu::UnicodeWidth.grapheme_width(grapheme).to_i
  end

  def self.width(text : String) : Int32
    total = 0
    text.each_grapheme { |g| total += grapheme_width(g.to_s) }
    total
  end

  def self.width(line : StyledLine) : Int32
    line.sum(&.width)
  end

  def self.plain(line : StyledLine) : String
    String.build { |io| line.each { |s| io << s.text } }
  end

  def self.line(text : String, style : Style = Style::NONE) : StyledLine
    text.empty? ? EMPTY_LINE.dup : [Span.new(text, style)]
  end

  # Kürzt auf `width` Spalten. Mit `ellipsis` wird dafür Platz freigehalten,
  # und das Kürzel erbt den Stil des Spans, an dem geschnitten wurde — sonst
  # springt es optisch aus der Zeile.
  def self.truncate(line : StyledLine, width : Int32, ellipsis : String? = nil) : StyledLine
    return EMPTY_LINE.dup if width <= 0
    return line if self.width(line) <= width

    ell_width = ellipsis ? self.width(ellipsis) : 0
    budget = width - ell_width
    return EMPTY_LINE.dup if budget <= 0

    out = StyledLine.new
    used = 0
    last_style = Style::NONE

    line.each do |span|
      last_style = span.style
      w = span.width
      if used + w <= budget
        out << span unless span.empty?
        used += w
        next
      end

      taken = String.build do |io|
        span.text.each_grapheme do |g|
          gw = grapheme_width(g.to_s)
          break if used + gw > budget
          io << g
          used += gw
        end
      end
      out << Span.new(taken, span.style) unless taken.empty?
      break
    end

    out << Span.new(ellipsis, last_style) if ellipsis
    out
  end

  # Bricht auf `width` Spalten um und liefert die entstandenen Zeilen.
  #
  # Umbrochen wird über Span-Grenzen hinweg — ein Wort, das in einem Span
  # beginnt und im nächsten endet, bleibt zusammen und behält je Teil seinen
  # eigenen Stil. Passt ein einzelnes Wort nicht in eine ganze Zeile, wird es
  # hart getrennt, statt eine überbreite Zeile zu erzeugen: die Zusage "eine
  # Zeile ist nie breiter als `width`" ist das, worauf die Inline-Region
  # ihre Höhenrechnung stützt.
  def self.wrap(line : StyledLine, width : Int32) : Array(StyledLine)
    # Eine nicht-positive Breite auf eine Spalte klemmen, statt den Inhalt
    # zurückzugeben oder zu verschlucken: ein Fenster kann kurzzeitig 0 Spalten
    # melden (während einer Größenänderung), und dabei Text zu verlieren wäre
    # der schlechteste Ausgang.
    width = 1 if width < 1
    return [EMPTY_LINE.dup] if line.empty?

    out = Array(StyledLine).new
    split_newlines(line).each do |segment|
      if self.width(segment) <= width
        out << segment
      else
        out.concat(Wrapper.new(width).run(segment))
      end
    end
    out
  end

  # Ein eingebetteter Zeilenumbruch ist ein Umbruch, kein Zeichen: bliebe er
  # stehen, landete er als Steuerzeichen in einer Zelle. Getrennt wird über
  # Span-Grenzen hinweg, die Stile bleiben je Teil erhalten.
  private def self.split_newlines(line : StyledLine) : Array(StyledLine)
    return [line.dup] unless line.any? { |span| span.text.includes?('\n') }

    out = Array(StyledLine).new
    current = StyledLine.new
    line.each do |span|
      parts = span.text.split('\n')
      parts.each_with_index do |part, i|
        if i > 0
          out << current
          current = StyledLine.new
        end
        # CRLF: das Wagenrücklaufzeichen gehört genauso wenig in eine Zelle.
        part = part.rchop('\r')
        append(current, part, span.style) unless part.empty?
      end
    end
    out << current
    out
  end

  # Der Umbruch als eigener Zustand statt als Kette von Closures: er muss
  # Zeile, Spaltenzähler und das noch nicht platzierte Wort gleichzeitig
  # fortschreiben, und das liest sich als Methoden schlicht besser.
  private class Wrapper
    def initialize(@width : Int32)
      @out = Array(StyledLine).new
      @current = StyledLine.new
      @used = 0
      @word = Array(Span).new
      @word_width = 0
    end

    def run(line : StyledLine) : Array(StyledLine)
      line.each do |span|
        span.text.each_grapheme do |g|
          gs = g.to_s
          if gs == " "
            take_space(span.style)
          else
            @word << Span.new(gs, span.style)
            @word_width += Text.grapheme_width(gs)
          end
        end
      end

      place_word
      @out << @current unless @current.empty? && !@out.empty?
      @out << EMPTY_LINE.dup if @out.empty?
      @out
    end

    private def take_space(style : Style) : Nil
      place_word
      # Führende Leerzeichen einer umbrochenen Zeile werden verworfen, sonst
      # beginnt jede Folgezeile eingerückt.
      return if @used == 0
      if @used + 1 > @width
        break_line
      else
        Text.append(@current, " ", style)
        @used += 1
      end
    end

    private def place_word : Nil
      return if @word.empty?

      if @word_width > @width
        hard_break_word
      else
        break_line if @used + @word_width > @width && @used > 0
        @word.each { |piece| Text.append(@current, piece.text, piece.style) }
        @used += @word_width
      end

      @word = Array(Span).new
      @word_width = 0
    end

    # Ein Wort, das in keine Zeile passt, wird Grapheme für Grapheme getrennt.
    # Die Zusage "keine Zeile ist breiter als `width`" wiegt schwerer als ein
    # unversehrtes Wort — die Inline-Region stützt ihre Höhenrechnung darauf.
    private def hard_break_word : Nil
      @word.each do |piece|
        piece.text.each_grapheme do |g|
          gs = g.to_s
          gw = Text.grapheme_width(gs)
          break_line if @used + gw > @width
          Text.append(@current, gs, piece.style)
          @used += gw
        end
      end
    end

    private def break_line : Nil
      # Ein Trennzeichen, das genau auf den Umbruch fällt, ist unsichtbar —
      # aber es zählt gegen die Breite, und eine Zeile, die auf Leerzeichen
      # endet, füllt beim Zeichnen Zellen mit Hintergrundfarbe. Also weg damit.
      trim_trailing_spaces
      @out << @current
      @current = StyledLine.new
      @used = 0
    end

    private def trim_trailing_spaces : Nil
      while (last = @current.last?)
        stripped = last.text.rstrip(' ')
        removed = last.text.size - stripped.size
        break if removed == 0
        @used -= removed
        if stripped.empty?
          @current.pop
        else
          @current[-1] = last.with_text(stripped)
          break
        end
      end
    end
  end

  # Hängt Text an die Zeile und führt ihn mit dem letzten Span zusammen, wenn
  # die Stile gleich sind — sonst entstünde pro Grapheme ein eigener Span und
  # der Renderer bekäme statt eines Batches hunderte.
  protected def self.append(line : StyledLine, text : String, style : Style) : Nil
    if (last = line.last?) && last.style == style
      line[-1] = last.with_text(last.text + text)
    else
      line << Span.new(text, style)
    end
  end

  # Farbanteil einer SGR-Sequenz. `base` ist 38 für Vorder-, 48 für Hintergrund.
  def self.sgr_color(color : Color, base : Int32) : String
    case color.mode
    when .rgb?     then "#{base};2;#{color.r};#{color.g};#{color.b}"
    when .ansi256? then "#{base};5;#{color.index}"
    else                (base == 38 ? 30 + color.index : 40 + color.index).to_s
    end
  end

  # Schreibt eine gestylte Zeile als ANSI in ein IO.
  #
  # Mit `color: false` kommt reiner Text heraus — für Pipes, Protokolle und
  # Tests, die sich nicht mit Escape-Sequenzen herumschlagen wollen.
  def self.render(line : StyledLine, io : IO, color : Bool = true) : Nil
    current = Style::NONE
    line.each do |span|
      style = span.style
      if color && style != current
        # Zurücksetzen, bevor ein neuer Stil kommt: sonst bleiben Attribute
        # des vorigen Spans stehen, die der neue nicht ausdrücklich abwählt.
        io << "\e[0m" unless current.plain?
        io << style.ansi
        current = style
      end
      io << span.text
    end
    io << "\e[0m" if color && !current.plain?
  end

  def self.to_ansi(line : StyledLine, color : Bool = true) : String
    String.build { |io| render(line, io, color) }
  end

  # Benannte Rollen statt Zahlen im Aufrufercode.
  module Palette
    ACCENT   = Color.ansi256(39)
    INFO     = Color.ansi256(245)
    WARN     = Color.ansi256(214)
    ERROR    = Color.ansi256(203)
    SUCCESS  = Color.ansi256(78)
    MUTED    = Color.ansi256(240)
    THINKING = Color.ansi256(140)
  end
end
