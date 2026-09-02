require "./spec_helper"

include Anvil

# A tiny grid terminal: it replays exactly what the inline surface writes.
# Lines falling off the top are kept — that is the scrollback the whole
# approach must not destroy.
class TinyScreen
  getter scrollback : Array(String)
  @grid : Array(Array(Char))

  def initialize(@width : Int32 = 40, @height : Int32 = 10)
    @grid = Array.new(@height) { Array.new(@width, ' ') }
    @scrollback = [] of String
    @row = 0
    @col = 0
  end

  def self.replay(bytes : String, width = 40, height = 10) : TinyScreen
    new(width, height).feed(bytes)
  end

  def screen_lines : Array(String)
    @grid.map(&.join.rstrip)
  end

  def all_lines : Array(String)
    @scrollback + screen_lines
  end

  def feed(text : String) : TinyScreen
    i = 0
    chars = text.chars
    while i < chars.size
      c = chars[i]
      i += 1
      case c
      when '\r' then @col = 0
      when '\n' then line_feed
      when '\e'
        next unless chars[i]? == '['
        i += 1
        params = String.build do |io|
          while (b = chars[i]?) && !('A' <= b <= 'Z') && !('a' <= b <= 'z')
            io << b
            i += 1
          end
        end
        final = chars[i]?
        i += 1
        apply(params, final)
      else
        put(c)
      end
    end
    self
  end

  private def apply(params : String, final : Char?)
    n = params.lchop('?').to_i? || 1
    case final
    when 'A' then @row = {@row - n, 0}.max
    when 'B' then @row = {@row + n, @height - 1}.min
    when 'G' then @col = n - 1
    when 'K' then (@col...@width).each { |x| @grid[@row][x] = ' ' } if params == "2" || params.empty?
    when 'J'
      if params == "0" || params.empty?
        (@col...@width).each { |x| @grid[@row][x] = ' ' }
        ((@row + 1)...@height).each { |y| @grid[y] = Array.new(@width, ' ') }
      elsif params == "2"
        @grid = Array.new(@height) { Array.new(@width, ' ') }
      end
    when 'H' then @row = 0; @col = 0
    end
  end

  private def put(c : Char)
    return if @col >= @width
    @grid[@row][@col] = c
    @col += 1
  end

  private def line_feed
    if @row == @height - 1
      @scrollback << @grid.shift.join.rstrip
      @grid << Array.new(@width, ' ')
    else
      @row += 1
    end
  end
end

private def surface(io, height = 3, width = 40, screen = 10)
  Surface::Inline.memory(io, width, screen, height)
end

describe Anvil::Surface::Inline do
  it "draws the region at the bottom" do
    io = IO::Memory.new
    s = surface(io, 2)
    s.put_line(0, 0, Text.line("oben"))
    s.put_line(0, 1, Text.line("unten"))
    s.end_frame

    lines = TinyScreen.replay(io.to_s).screen_lines
    lines[0].should eq "oben"
    lines[1].should eq "unten"
  end

  it "writes committed content permanently above the region" do
    io = IO::Memory.new
    s = surface(io, 1)
    s.commit([Text.line("bleibt stehen")])
    s.put_line(0, 0, Text.line("lebendig"))
    s.end_frame

    all = TinyScreen.replay(io.to_s).all_lines
    all.should contain "bleibt stehen"
    all.should contain "lebendig"
    # Order: committed content stands above the region.
    all.index("bleibt stehen").not_nil!.should be < all.index("lebendig").not_nil!
  end

  it "leaves no remains of the old height when shrinking" do
    io = IO::Memory.new
    s = surface(io, 4)
    (0..3).each { |y| s.put_line(0, y, Text.line("zeile #{y}")) }
    s.end_frame

    s.height = 2
    s.put_line(0, 0, Text.line("neu 0"))
    s.put_line(0, 1, Text.line("neu 1"))
    s.end_frame

    lines = TinyScreen.replay(io.to_s).screen_lines.reject(&.empty?)
    lines.should eq ["neu 0", "neu 1"]
  end

  it "caps the height at the screen" do
    # A taller region could not be walked back over; every redraw would push
    # a copy into the scrollback.
    io = IO::Memory.new
    s = surface(io, 1, screen: 6)
    s.height = 99
    s.height.should eq 5
  end

  it "emits only the cells that changed" do
    io = IO::Memory.new
    s = surface(io, 1)
    s.put_line(0, 0, Text.line("gleich"))
    s.end_frame
    before = io.to_s.size

    s.put_line(0, 0, Text.line("gleich"))
    s.end_frame
    # Only the frame's wrapping sequences, no cells.
    (io.to_s.size - before).should be < 30
  end

  it "draws in full again after invalidate!" do
    io = IO::Memory.new
    s = surface(io, 1)
    s.put_line(0, 0, Text.line("inhalt"))
    s.end_frame

    s.invalidate!
    io.clear
    s.put_line(0, 0, Text.line("inhalt"))
    s.end_frame
    io.to_s.should contain "inhalt"
  end
end

describe "Anvil::Surface::Inline after committing" do
  it "asks for no rows beyond the committed ones" do
    # Asking for the old height again would push the screen too far up and
    # leave a gap below the region — exactly what one sees when a streamed
    # answer finishes.
    io = IO::Memory.new
    s = surface(io, 6)
    (0..5).each { |y| s.put_line(0, y, Text.line("streamt #{y}")) }
    s.end_frame

    io.clear
    s.commit([Text.line("fertig 1"), Text.line("fertig 2")])
    # Two lines committed, so exactly two line feeds.
    io.to_s.scan("\r\n").size.should eq 2
    s.height.should eq 1
  end

  it "then grows only by what the new frame needs" do
    io = IO::Memory.new
    s = surface(io, 6)
    s.commit([Text.line("fertig")])

    io.clear
    s.height = 3
    io.to_s.scan("\r\n").size.should eq 2
  end

  it "leaves no gap below the region" do
    io = IO::Memory.new
    s = surface(io, 5)
    (0..4).each { |y| s.put_line(0, y, Text.line("lang #{y}")) }
    s.end_frame

    s.commit([Text.line("committet")])
    s.height = 2
    s.put_line(0, 0, Text.line("status"))
    s.put_line(0, 1, Text.line("> "))
    s.end_frame

    lines = TinyScreen.replay(io.to_s).all_lines.reject(&.empty?)
    lines.last(3).should eq ["committet", "status", ">"]
  end
end
