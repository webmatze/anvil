require "../text"

module Anvil::Widgets
  # Gefilterte Auswahlliste über der Eingabezeile — Slash-Kommandos,
  # Dateivervollständigung, alles dieser Art.
  #
  # Hält nur den Zustand und liefert Zeilen; wann sie aufgeht und was die
  # Auswahl bedeutet, entscheidet die App.
  class ListPopup(T)
    getter items : Array(T)
    getter selected : Int32
    getter top : Int32
    getter query : String

    # Die vollständige Trefferliste — `visible` ist nur das Fenster darauf.
    getter matches : Array(T)

    # `label` und `description` sagen, wie ein Eintrag zu Text wird — so
    # bleibt das Popup unabhängig davon, was es anzeigt.
    #
    # `filter` bestimmt, was auf eine Eingabe passt. Die Vorgabe ist eine
    # Teilzeichenkette ohne Rücksicht auf Groß- und Kleinschreibung; eine App
    # mit eigener Vorstellung (Präfixe, Fuzzy-Suche, eigene Sortierung) gibt
    # ihre eigene mit, statt dass das Popup alle Fälle zu kennen versucht.
    #
    # `wrap_around` sagt, ob die Auswahl am Ende der Liste oben weitermacht.
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

    # Hält die Auswahl im sichtbaren Fenster — auch beim Umlauf von unten
    # nach oben, wo sonst das Fenster stehen bliebe und die Auswahl
    # verschwände.
    private def scroll_into_view : Nil
      if @selected < @top
        @top = @selected
      elsif @selected >= @top + @max_visible
        @top = @selected - @max_visible + 1
      end

      # Nicht über das Ende hinaus scrollen: sonst zeigt das Fenster bei einer
      # kurzen Liste Leerzeilen unter dem letzten Eintrag.
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
