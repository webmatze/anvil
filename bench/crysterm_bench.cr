require "crysterm"
require "./support/harness"

# crysterm implementation of the same two scenarios.
#
# crysterm normally paints through widgets and content strings, but for a
# like-for-like comparison we bypass that with a full-window custom paint
# handler that writes the very same cells termisu and the baseline write.
# `fill_region` on a 1x1 rect is crysterm's own change-guarded per-cell
# writer, so its diff and dirty tracking stay in play - only the widget
# tree and layout are taken out of the picture.
class CrystermBench
  include Crysterm
  include Crysterm::Widgets

  def initialize(@config : Bench::Config)
    @stats = Bench::FrameStats.new(@config.frames)
    @frame = 0
    @paint_calls = 0
    @cells_written = 0_i64
    @attr_cache = Hash(UInt64, Int64).new

    @window = Window.new title: "crysterm bench"
    @window.synchronized_output = (@config.variant != "nosync")

    @canvas = Box.new parent: @window, width: "100%", height: "100%"
    @canvas.paint_handler do |xi, xl, yi, yl|
      paint(xi, xl, yi, yl)
    end
  end

  private def attr_for(fr, fg, fb, br, bg, bb) : Int64
    key = (fr.to_u64 << 40) | (fg.to_u64 << 32) | (fb.to_u64 << 24) |
          (br.to_u64 << 16) | (bg.to_u64 << 8) | bb.to_u64
    @attr_cache[key] ||= Attr.pack(
      0_i64,
      Attr.pack_color((fr.to_i32 << 16) | (fg.to_i32 << 8) | fb.to_i32),
      Attr.pack_color((br.to_i32 << 16) | (bg.to_i32 << 8) | bb.to_i32),
    )
  end

  private def paint(xi, xl, yi, yl)
    @paint_calls += 1
    w = xl - xi
    h = yl - yi
    window = @window
    f = @frame
    kind = @config.scenario
    y = 0
    while y < h
      x = 0
      while x < w
        c = Bench::Scenario.cell(kind, x, y, w, h, f)
        window.fill_region(
          attr_for(c.fr, c.fg_, c.fb, c.br, c.bg_, c.bb),
          c.ch, xi + x, xi + x + 1, yi + y, yi + y + 1)
        @cells_written += 1
        x += 1
      end
      y += 1
    end
  end

  def run
    # crysterm owns its own render loop, so the idiomatic driver is: mark the
    # widget dirty on every tick and let the render fiber build the frame.
    # `PreRender`/`Rendered` bracket exactly that frame - the paint handler
    # (our per-cell writes), the composite and the tty flush - which is the
    # same span the other implementations time around their own render call.
    @window.on(Event::PreRender) { @stats.frame_begin }
    @window.on(Event::Rendered) do
      @stats.frame_end
      @frame += 1
      @window.quit if @frame >= @config.frames
    end

    @stats.begin_run
    @window.every(@config.frame_interval) { @canvas.update! }
    @window.exec
    @stats.report(@config, {
      "grid"                    => "#{@window.width}x#{@window.height}",
      "paint_calls"             => @paint_calls,
      "cells_written_per_frame" => @cells_written / @config.frames.to_f,
    })
  end
end

CrystermBench.new(Bench::Config.new("crysterm")).run
