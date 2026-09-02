require "../surface"

module Anvil
  # A drawing surface in memory — for tests, and for anything that wants to
  # inspect output rather than show it (approval snapshots, bug reports).
  #
  # It keeps a grid of graphemes and remembers what was committed, which is
  # what lets the app layer's specs run without a terminal.
  class Surface::Memory < Surface
    getter commits : Array(Array(Text::StyledLine))
    getter height : Int32
    getter frames : Int32 = 0

    def initialize(@width : Int32 = 40, @height : Int32 = 10, @max_height : Int32 = 10)
      @grid = Array(Array(String)).new
      @styles = Array(Array(Text::Style)).new
      @commits = Array(Array(Text::StyledLine)).new
      @cursor = nil.as({Int32, Int32}?)
      allocate_rows(@height)
    end

    def size : {Int32, Int32}
      {@width, @height}
    end

    def max_height : Int32
      @max_height
    end

    def put_cell(x : Int32, y : Int32, grapheme : String, style : Text::Style) : Nil
      return if y < 0 || y >= @height || x < 0 || x >= @width
      @grid[y][x] = grapheme
      @styles[y][x] = style
    end

    def begin_frame : Nil
    end

    def end_frame : Nil
      @frames += 1
    end

    def invalidate! : Nil
    end

    def close : Nil
    end

    def commit(lines : Array(Text::StyledLine)) : Nil
      @commits << lines
    end

    def height=(value : Int32) : Nil
      return if value == @height
      @height = value
      allocate_rows(value)
    end

    def cursor_at(x : Int32, y : Int32) : Nil
      @cursor = {x, y}
    end

    def hide_cursor : Nil
      @cursor = nil
    end

    def cursor : {Int32, Int32}?
      @cursor
    end

    # What stands on the surface, as plain text — without trailing spaces, so
    # expectations in specs stay readable.
    def to_lines : Array(String)
      @grid.map { |row| row.join.rstrip }
    end

    def committed_text : Array(String)
      @commits.flat_map { |batch| batch.map { |line| Text.plain(line) } }
    end

    def style_at(x : Int32, y : Int32) : Text::Style
      @styles[y][x]
    end

    private def allocate_rows(n : Int32) : Nil
      @grid = Array.new(n) { Array.new(@width, " ") }
      @styles = Array.new(n) { Array.new(@width, Text::Style::NONE) }
    end
  end
end
