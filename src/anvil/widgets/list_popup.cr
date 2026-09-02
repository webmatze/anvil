require "../text"

module Anvil::Widgets
  # A filtered pick list above the input line — slash commands, file
  # completion, anything of that shape.
  #
  # It holds state and produces lines; when it opens and what a selection means
  # is the app's decision.
  class ListPopup(T)
    getter items : Array(T)
    getter selected : Int32
    getter top : Int32
    getter query : String

    # The complete match list — `visible` is only the window onto it.
    getter matches : Array(T)

    # `label` and `description` say how an entry becomes text — which keeps
    # the popup independent of what it is showing.
    #
    # `filter` decides what matches a query. The default is a case-insensitive
    # substring; an app with its own idea (prefixes, fuzzy search, its own
    # ordering) passes its own instead of the popup trying to know every case.
    #
    # `wrap_around` says whether the selection continues at the top once it
    # runs off the end of the list.
    def initialize(@items : Array(T), *, @max_visible : Int32 = 8,
                   @label : T -> String, @description : (T -> String)? = nil,
                   @filter : (Array(T), String -> Array(T))? = nil,
                   @wrap_around : Bool = true)
      @matches = @items.dup
      @selected = 0
      @top = 0
      @query = ""
    end

    def update(query : String) : Nil
      @query = query
      @matches = if custom = @filter
                   custom.call(@items, query)
                 elsif query.empty?
                   @items.dup
                 else
                   down = query.downcase
                   @items.select { |i| @label.call(i).downcase.includes?(down) }
                 end
      @selected = 0
      @top = 0
    end

    def open? : Bool
      !@matches.empty?
    end

    def size : Int32
      @matches.size
    end

    def current : T?
      @matches[@selected]?
    end

    def move_up : Nil
      return if @matches.empty?
      if @selected > 0
        @selected -= 1
      elsif @wrap_around
        @selected = @matches.size - 1
      end
      scroll_into_view
    end

    def move_down : Nil
      return if @matches.empty?
      if @selected < @matches.size - 1
        @selected += 1
      elsif @wrap_around
        @selected = 0
      end
      scroll_into_view
    end

    def visible : Array(T)
      @matches[@top, @max_visible]? || Array(T).new
    end

    # Keeps the selection inside the visible window — including when it wraps
    # from the bottom to the top, where the window would otherwise stay put and
    # the selection disappear.
    private def scroll_into_view : Nil
      if @selected < @top
        @top = @selected
      elsif @selected >= @top + @max_visible
        @top = @selected - @max_visible + 1
      end

      # Do not scroll past the end: on a short list the window would otherwise
      # show blank rows below the last entry.
      max_top = @matches.size - @max_visible
      max_top = 0 if max_top < 0
      @top = max_top if @top > max_top
      @top = 0 if @top < 0
    end

    def lines(width : Int32,
              marker_style : Text::Style = Text::Style.new(fg: Text::Palette::ACCENT),
              selected_style : Text::Style = Text::Style.new(reverse: true),
              normal_style : Text::Style = Text::Style.new(dim: true),
              separator_style : Text::Style = Text::Style.new(fg: Text::Palette::MUTED)) : Array(Text::StyledLine)
      visible.map_with_index do |item, i|
        index = @top + i
        chosen = index == @selected
        base = chosen ? selected_style : normal_style

        line = Text::StyledLine.new
        line << Text::Span.new(chosen ? "❯ " : "  ", marker_style)
        line << Text::Span.new(@label.call(item), Text::Style.new(bold: true).merge(base))
        if desc = @description
          text = desc.call(item)
          unless text.empty?
            line << Text::Span.new(" · ", separator_style)
            line << Text::Span.new(text, base)
          end
        end
        Text.truncate(line, width, "…")
      end
    end
  end
end
