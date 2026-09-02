require "termisu"
require "../text"

module Anvil::Widgets
  # A single-line input editor with history.
  #
  # The buffer is a list of grapheme clusters, not of characters: only that way
  # does the cursor move by *one* visible character when that character is made
  # of several codepoints (an emoji with a variation selector, e + accent).
  # Column arithmetic goes through the same width function as the renderer, or
  # the cursor would sit in the wrong place in CJK text.
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

    # Columns to the left of the cursor — what the surface needs to place it.
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

    # Handles a key. Returns the submitted text on Enter, `nil` otherwise.
    # Keys that are none of the editor's business are ignored — the app loop
    # sees them first anyway.
    def handle(event : Termisu::Event::Key) : String?
      key = event.key

      # Inside a paste every character is payload, Enter included: otherwise a
      # multi-line paste submits once per line.
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

    # Careful: for a Ctrl key the parser supplies the key enum and leaves
    # `char` empty (Ctrl-A is `Key::LowerA` plus the modifier). So the letter
    # has to come from the enum, not from `char`.
    private def handle_ctrl(event : Termisu::Event::Key) : Nil
      case event.key.to_char
      when 'a' then @cursor = 0
      when 'e' then @cursor = @buffer.size
      when 'b' then @cursor -= 1 if @cursor > 0
      when 'f' then @cursor += 1 if @cursor < @buffer.size
      when 'u' # kill to start
        @buffer = @buffer[@cursor..]
        @cursor = 0
      when 'k' # kill to end
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

    # Inserts text at the cursor — for pastes and anything else that fills the
    # buffer from outside.
    #
    # Newlines are flattened to spaces: they would break the single-line
    # layout, and a line break in the input line could not be shown anyway.
    def insert_text(text : String) : Nil
      insert(text.gsub(/\s*\n\s*/, " "))
    end

    private def insert(text : String) : Nil
      gs = graphemes(text)
      @buffer = @buffer[0...@cursor] + gs + @buffer[@cursor..]
      @cursor += gs.size
    end

    # Newlines in pasted text would break the single-line layout; they are
    # flattened to spaces.
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

    # The first step upwards saves the half-typed text, so the way back brings
    # it again.
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

    # The visible line plus the cursor column inside it, scrolled horizontally
    # when the text is wider than the field. The cursor always stays in view.
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
