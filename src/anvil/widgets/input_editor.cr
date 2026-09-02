require "termisu"
require "../text"

module Anvil::Widgets
  # Einzeiliger Eingabezeileneditor mit History.
  #
  # Der Puffer ist eine Liste von Grapheme-Clustern, nicht von Zeichen: nur so
  # bewegt sich der Cursor um *ein* sichtbares Zeichen, wenn dieses aus
  # mehreren Codepoints besteht (Emoji mit Variation Selector, e + Akzent).
  # Die Spaltenrechnung geht durch dieselbe Breitenfunktion wie der Renderer,
  # sonst steht der Cursor bei CJK-Text an der falschen Stelle.
  class InputEditor
    getter cursor : Int32
    getter history : Array(String)

    def initialize(@history : Array(String) = Array(String).new, @max_history : Int32 = 500)
      @buffer = Array(String).new
      @cursor = 0
      @history_index = @history.size
      @draft = ""
      @pasting = false
    end

    def text : String
      @buffer.join
    end

    def empty? : Bool
      @buffer.empty?
    end

    def reset : Nil
      @buffer.clear
      @cursor = 0
      @history_index = @history.size
      @draft = ""
    end

    def set_text(text : String) : Nil
      @buffer = graphemes(text)
      @cursor = @buffer.size
    end

    # Spalten links vom Cursor — was die Surface braucht, um ihn zu setzen.
    def columns_before_cursor : Int32
      w = 0
      i = 0
      while i < @cursor
        w += Text.grapheme_width(@buffer[i])
        i += 1
      end
      w
    end

    def display_width : Int32
      @buffer.sum { |g| Text.grapheme_width(g) }
    end

    # Verarbeitet eine Taste. Liefert den abgesendeten Text bei Enter,
    # sonst `nil`. Tasten, die den Editor nichts angehen, werden ignoriert —
    # die App-Schleife sieht sie ohnehin zuerst.
    def handle(event : Termisu::Event::Key) : String?
      key = event.key

      # Innerhalb eines Einfügevorgangs ist jedes Zeichen Nutzlast, auch
      # Enter: sonst löst mehrzeiliges Einfügen pro Zeile ein Absenden aus.
      case key
      when .paste_start? then @pasting = true; return nil
      when .paste_end?   then @pasting = false; return nil
      end

      if @pasting
        insert_pasted(event)
        return nil
      end

      if event.ctrl?
        handle_ctrl(event)
        return nil
      end

      case key
      when .enter?     then return submit
      when .backspace? then backspace
      when .delete?    then delete_forward
      when .left?      then @cursor -= 1 if @cursor > 0
      when .right?     then @cursor += 1 if @cursor < @buffer.size
      when .home?      then @cursor = 0
      when .end?       then @cursor = @buffer.size
      when .up?        then history_previous
      when .down?      then history_next
      else
        if ch = event.char
          insert(ch.to_s)
        end
      end
      nil
    end

    # Achtung: bei einer Ctrl-Taste liefert der Parser das Key-Enum und
    # `char` bleibt leer (Ctrl-A ist `Key::LowerA` plus Modifier). Der
    # Buchstabe muss also aus dem Enum kommen, nicht aus `char`.
    private def handle_ctrl(event : Termisu::Event::Key) : Nil
      case event.key.to_char
      when 'a' then @cursor = 0
      when 'e' then @cursor = @buffer.size
      when 'b' then @cursor -= 1 if @cursor > 0
      when 'f' then @cursor += 1 if @cursor < @buffer.size
      when 'u' # bis zum Anfang löschen
        @buffer = @buffer[@cursor..]
        @cursor = 0
      when 'k' # bis zum Ende löschen
        @buffer = @buffer[0...@cursor]
      when 'w' then kill_word_back
      end
    end

    private def kill_word_back : Nil
      i = @cursor
      while i > 0 && @buffer[i - 1] == " "
        i -= 1
      end
      while i > 0 && @buffer[i - 1] != " "
        i -= 1
      end
      @buffer = @buffer[0...i] + @buffer[@cursor..]
      @cursor = i
    end

    # Text an der Cursorposition einfügen — für Einfügevorgänge und alles,
    # was den Puffer von außen füllt.
    #
    # Zeilenumbrüche werden zu Leerzeichen geglättet: sie würden das
    # einzeilige Layout sprengen, und ein Umbruch in der Eingabezeile wäre
    # ohnehin nicht darstellbar.
    def insert_text(text : String) : Nil
      insert(text.gsub(/\s*\n\s*/, " "))
    end

    private def insert(text : String) : Nil
      gs = graphemes(text)
      @buffer = @buffer[0...@cursor] + gs + @buffer[@cursor..]
      @cursor += gs.size
    end

    # Zeilenumbrüche im eingefügten Text würden das einzeilige Layout
    # sprengen; sie werden zu Leerzeichen geglättet.
    private def insert_pasted(event : Termisu::Event::Key) : Nil
      if event.key.enter?
        insert(" ") unless @buffer.last? == " "
      elsif ch = event.char
        insert(ch.to_s)
      end
    end

    private def backspace : Nil
      return if @cursor == 0
      @buffer.delete_at(@cursor - 1)
      @cursor -= 1
    end

    private def delete_forward : Nil
      @buffer.delete_at(@cursor) if @cursor < @buffer.size
    end

    private def submit : String
      value = text
      unless value.strip.empty?
        @history << value unless @history.last? == value
        @history.shift if @history.size > @max_history
      end
      reset
      value
    end

    # Beim ersten Schritt nach oben wird der angefangene Text gesichert, damit
    # der Weg zurück ihn wiederbringt.
    private def history_previous : Nil
      return if @history.empty? || @history_index == 0
      @draft = text if @history_index == @history.size
      @history_index -= 1
      set_text(@history[@history_index])
    end

    private def history_next : Nil
      return if @history_index >= @history.size
      @history_index += 1
      if @history_index == @history.size
        set_text(@draft)
      else
        set_text(@history[@history_index])
      end
    end

    private def graphemes(text : String) : Array(String)
      out = Array(String).new
      text.each_grapheme { |g| out << g.to_s }
      out
    end

    # Die sichtbare Zeile plus die Cursorspalte darin, horizontal gescrollt,
    # wenn der Text breiter ist als das Feld. Der Cursor bleibt dabei immer
    # im Bild.
    def view(width : Int32, style : Text::Style = Text::Style::NONE) : {Text::StyledLine, Int32}
      return {Text::EMPTY_LINE.dup, 0} if width <= 0

      cursor_col = columns_before_cursor
      offset = 0
      offset = cursor_col - width + 1 if cursor_col >= width
      offset = 0 if offset < 0

      visible = String.build do |io|
        col = 0
        @buffer.each do |g|
          gw = Text.grapheme_width(g)
          io << g if col >= offset && col + gw <= offset + width
          col += gw
        end
      end

      {Text.line(visible, style), cursor_col - offset}
    end
  end
end
