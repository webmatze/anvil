require "termisu"
require "./support/harness"

# termisu implementation of the same two scenarios.
#
# Idiomatic usage: the library owns the cell buffer, the diff and the event
# loop; we only push cells and call `render`. Variants let us compare the
# portable sleep-based timer against the kernel timer (kqueue on macOS) and
# measure the cost of DEC 2026 synchronized output.
config = Bench::Config.new("termisu")
sync = config.variant != "nosync"

term = Termisu.new(sync_updates: sync)
stats = Bench::FrameStats.new(config.frames)
w, h = term.size

# Colors are immutable value objects; building 10k of them per frame would
# measure the allocator, not the renderer. The scenario's palette is small
# enough to cache by RGB triple.
color_cache = Hash(UInt32, Termisu::Color).new
color_for = ->(r : UInt8, g : UInt8, b : UInt8) do
  key = (r.to_u32 << 16) | (g.to_u32 << 8) | b.to_u32
  color_cache[key] ||= Termisu::Color.rgb(r.to_i, g.to_i, b.to_i)
end

begin
  if config.variant == "systimer"
    term.enable_system_timer(config.frame_interval)
  else
    term.enable_timer(config.frame_interval)
  end

  frame = 0
  stats.begin_run
  term.each_event do |event|
    case event
    when Termisu::Event::Tick
      stats.record_missed(event.missed_ticks)
      stats.frame_begin
      y = 0
      while y < h
        x = 0
        while x < w
          c = Bench::Scenario.cell(config.scenario, x, y, w, h, frame)
          term.set_cell(x, y, c.ch, color_for.call(c.fr, c.fg_, c.fb), color_for.call(c.br, c.bg_, c.bb))
          x += 1
        end
        y += 1
      end
      term.render
      stats.frame_end
      frame += 1
      break if frame >= config.frames
    end
  end
ensure
  term.close
end

stats.report(config, {"grid" => "#{w}x#{h}"})
