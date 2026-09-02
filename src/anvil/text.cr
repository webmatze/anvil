require "termisu"

# The styled-text layer.
#
# termisu is a *cell* buffer: it knows cells, colors and widths, but nothing
# about lines, spans or wrapping. That is what lives here — and it is the part
# an app would otherwise write again every time.
#
# Widths come from `Termisu::UnicodeWidth` so that the wrapping arithmetic
# holds the same opinion about "how wide is this" as the renderer that later
# draws it. Two sources would be a bug waiting to happen: what counts as 79
# columns here has to fit into 79 cells there.
module Anvil::Text
  alias Color = Termisu::Color
  alias Attribute = Termisu::Attribute

  # A style. `nil` for fg/bg means "not set" — which is distinct from
  # `Color.default` ("the terminal's own default, deliberately"), and is what
  # makes `merge` able to layer at all.
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
      # Not `@attr.none?`: `Attribute` is a @[Flags] enum with `None = 0`, and
      # Crystal generates that member's predicate as "all bits of None set" —
      # which is true for every value when the member is zero. `Bold.none?`
      # returns `true`.
      @fg.nil? && @bg.nil? && @attr.value.zero?
    end

    # `other` wins wherever it has something to say; attributes add up.
    def merge(other : Style) : Style
      Style.new(other.fg || @fg, other.bg || @bg, @attr | other.attr)
    end

    # One predicate per attribute. The individual members are safe — only
    # `none?` is always true on a @[Flags] enum with a zero member, see
    # `#plain?`.
    {% for name in %w[bold dim italic underline reverse blink hidden strikethrough] %}
      def {{name.id}}? : Bool
        @attr.{{name.id}}?
      end
    {% end %}

    # The constructor takes `strike:`; this is the matching reader.
    def strike? : Bool
      @attr.strikethrough?
    end

    # The SGR sequence for this style, or "" when there is nothing to set.
    #
    # Needed wherever a line is written *once* and never diffed: content
    # committed to the scrollback, output to a file, approval snapshots. The
    # cell buffer takes a different route.
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

    # Colors resolved the way the renderer needs them.
    def resolved_fg : Color
      @fg || Color.default
    end

    def resolved_bg : Color
      @bg || Color.default
    end
  end

  # A run of text with a single style.
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

  # Width of a single grapheme cluster.
  def self.grapheme_width(grapheme : String) : Int32
    Termisu::UnicodeWidth.grapheme_width(grapheme).to_i
  end

  # Display width in terminal columns. Grapheme clusters, not codepoints: an
  # emoji with a variation selector means one cell and is two codepoints long.
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

  # Truncates to `width` columns. Room is reserved for `ellipsis`, and the
  # ellipsis inherits the style of the span it cut into — otherwise it stands
  # out from the line it belongs to.
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

  # Wraps to `width` columns and returns the resulting lines.
  #
  # Wrapping crosses span boundaries — a word that starts in one span and ends
  # in the next stays together, each part keeping its own style. A word that
  # does not fit a whole line is broken hard rather than producing an
  # over-wide line: the promise that "no line is ever wider than `width`" is
  # what the inline region bases its height arithmetic on.
  def self.wrap(line : StyledLine, width : Int32) : Array(StyledLine)
    # Clamp a non-positive width to one column rather than returning the
    # content untouched or swallowing it: a window can briefly report 0
    # columns during a resize, and losing text there is the worst outcome.
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

  # An embedded newline is a break, not a character: left in place it would
  # end up in a cell as a control character. Splitting crosses span
  # boundaries, and each part keeps its style.
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
        # CRLF: the carriage return has no business in a cell either.
        part = part.rchop('\r')
        append(current, part, span.style) unless part.empty?
      end
    end
    out << current
    out
  end

  # Wrapping as its own piece of state rather than a chain of closures: it has
  # to advance the line, the column count and the not-yet-placed word at the
  # same time, and that simply reads better as methods.
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
      # Leading spaces on a wrapped line are dropped, or every continuation
      # line would start indented.
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

    # A word that fits no line at all is broken grapheme by grapheme. The
    # promise that "no line is wider than `width`" outweighs an intact word —
    # the inline region rests its height arithmetic on it.
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
      # A separator landing exactly on the break is invisible — but it counts
      # against the width, and a line ending in spaces fills cells with
      # background color when drawn. So it goes.
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

  # Appends text to the line, merging it into the last span when the styles
  # match — otherwise every grapheme would become its own span and the
  # renderer would get hundreds of batches instead of one.
  protected def self.append(line : StyledLine, text : String, style : Style) : Nil
    if (last = line.last?) && last.style == style
      line[-1] = last.with_text(last.text + text)
    else
      line << Span.new(text, style)
    end
  end

  # The color part of an SGR sequence. `base` is 38 for foreground, 48 for
  # background.
  def self.sgr_color(color : Color, base : Int32) : String
    case color.mode
    when .rgb?     then "#{base};2;#{color.r};#{color.g};#{color.b}"
    when .ansi256? then "#{base};5;#{color.index}"
    else                (base == 38 ? 30 + color.index : 40 + color.index).to_s
    end
  end

  # Writes a styled line to an IO as ANSI.
  #
  # With `color: false` the result is plain text — for pipes, logs and tests
  # that would rather not wrestle with escape sequences.
  def self.render(line : StyledLine, io : IO, color : Bool = true) : Nil
    current = Style::NONE
    line.each do |span|
      style = span.style
      if color && style != current
        # Reset before a new style: otherwise attributes of the previous span
        # survive wherever the new one does not explicitly turn them off.
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

  # Named roles instead of numbers in calling code.
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
