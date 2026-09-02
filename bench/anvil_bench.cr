require "../src/anvil"
require "./support/harness"

# The same scenario as the other implementations, but through
# `Anvil::Surface::Fullscreen`. The point is not to compare against termisu —
# termisu is what sits underneath — but to ask what the abstraction costs.
# Any divergence from `bin/termisu` is time the surface layer lost.
config = Bench::Config.new("anvil")
sync = config.variant != "nosync"

backend = Anvil::Backend.new(alternate_screen: true, sync_updates: sync)
surface = Anvil::Surface::Fullscreen.new(backend)
stats = Bench::FrameStats.new(config.frames)
w, h = surface.size

# Cache styles, for the same reason as in the termisu benchmark: 10,000 value
# objects per frame would measure the allocator, not the surface.
style_cache = Hash(UInt64, Anvil::Text::Style).new
style_for = ->(fr : UInt8, fg : UInt8, fb : UInt8, br : UInt8, bg : UInt8, bb : UInt8) do
  key = (fr.to_u64 << 40) | (fg.to_u64 << 32) | (fb.to_u64 << 24) |
        (br.to_u64 << 16) | (bg.to_u64 << 8) | bb.to_u64
  style_cache[key] ||= Anvil::Text::Style.new(
    fg: Anvil::Text::Color.rgb(fr.to_i, fg.to_i, fb.to_i),
    bg: Anvil::Text::Color.rgb(br.to_i, bg.to_i, bb.to_i))
end

begin
  stats.begin_run
  interval = config.frame_interval
  next_at = Time.instant
  frame = 0
  while frame < config.frames
    stats.frame_begin
    surface.begin_frame
    y = 0
    while y < h
      x = 0
      while x < w
        c = Bench::Scenario.cell(config.scenario, x, y, w, h, frame)
        surface.put_cell(x, y, c.ch, style_for.call(c.fr, c.fg_, c.fb, c.br, c.bg_, c.bb))
        x += 1
      end
      y += 1
    end
    surface.end_frame
    stats.frame_end

    next_at += interval
    remaining = next_at - Time.instant
    if remaining > Time::Span.zero
      sleep remaining
    else
      stats.record_missed(1_u64)
    end
    frame += 1
  end
ensure
  surface.close
end

stats.report(config, {"grid" => "#{w}x#{h}"})
