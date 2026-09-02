require "../src/anvil"
require "./support/harness"

# The case that matters for an inline app.
#
# The fullscreen scenarios measure bytes per full-screen frame; an app like
# smith never draws a full screen, only a live region of 10–20 lines in which
# a few cells change per frame. The number that counts is therefore "bytes per
# redraw of the region".
#
# BENCH_REGION sets the region height, BENCH_CHANGED how many lines change per
# frame.
config = Bench::Config.new("inline")
region_height = (ENV["BENCH_REGION"]? || "15").to_i
changed_lines = (ENV["BENCH_CHANGED"]? || "2").to_i

backend = Anvil::Backend.new(alternate_screen: false, sync_updates: config.variant != "nosync")
surface = Anvil::Surface::Inline.new(backend, height: 1)
surface.height = {region_height, surface.max_height}.min

accent = Anvil::Text::Style.new(fg: Anvil::Text::Palette::ACCENT)
dim = Anvil::Text::Style.new(fg: Anvil::Text::Palette::MUTED)
stats = Bench::FrameStats.new(config.frames)

# The static part is written once and must never change — which is exactly
# what the diff should confirm: after the first frame it costs nothing.
static = (0...surface.height).map do |i|
  Anvil::Text.line("  line #{i}: unchanged content, as a control", dim)
end

begin
  stats.begin_run
  interval = config.frame_interval
  next_at = Time.instant
  frame = 0
  spinner = {"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}

  while frame < config.frames
    stats.frame_begin
    static.each_with_index { |line, y| surface.put_line(0, y, line) }

    changed_lines.times do |n|
      y = (surface.height - 1 - n)
      next if y < 0
      line = Anvil::Text::StyledLine.new
      line << Anvil::Text::Span.new("#{spinner[(frame + n) % spinner.size]} ", accent)
      line << Anvil::Text::Span.new("frame #{frame}, line #{n}", dim)
      surface.put_line(0, y, line)
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

stats.report(config, {
  # The scenario field of the fullscreen runs does not fit here; overridden so
  # the report does not claim "churn".
  "scenario"      => "inline-region",
  "grid"          => "#{surface.width}x#{surface.height}",
  "region_height" => surface.height,
  "changed_lines" => changed_lines,
})
