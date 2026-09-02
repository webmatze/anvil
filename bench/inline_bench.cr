require "../src/anvil"
require "./support/harness"

# Der Fall, der für eine Inline-App zählt.
#
# Die Fullscreen-Szenarien messen Bytes pro Vollbild-Frame; eine App wie
# smith zeichnet aber nie ein Vollbild, sondern eine Live-Region von 10–20
# Zeilen, in der sich pro Frame ein paar Zellen ändern. Die maßgebliche
# Größe ist deshalb "Bytes pro Redraw der Region".
#
# BENCH_REGION setzt die Regionshöhe, BENCH_CHANGED wie viele Zeilen sich je
# Frame ändern.
config = Bench::Config.new("inline")
region_height = (ENV["BENCH_REGION"]? || "15").to_i
changed_lines = (ENV["BENCH_CHANGED"]? || "2").to_i

backend = Anvil::Backend.new(alternate_screen: false, sync_updates: config.variant != "nosync")
surface = Anvil::Surface::Inline.new(backend, height: 1)
surface.height = {region_height, surface.max_height}.min

accent = Anvil::Text::Style.new(fg: Anvil::Text::Palette::ACCENT)
dim = Anvil::Text::Style.new(fg: Anvil::Text::Palette::MUTED)
stats = Bench::FrameStats.new(config.frames)

# Der statische Teil steht einmal und darf sich nie ändern — genau das soll
# der Diff auch bestätigen: er kostet nach dem ersten Frame nichts mehr.
static = (0...surface.height).map do |i|
  Anvil::Text.line("  Zeile #{i}: unveränderter Inhalt zur Kontrolle", dim)
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
      line << Anvil::Text::Span.new("Frame #{frame}, Zeile #{n}", dim)
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
  # Das Szenariofeld der Fullscreen-Läufe passt hier nicht; überschrieben,
  # damit der Bericht nicht "churn" behauptet.
  "scenario"      => "inline-region",
  "grid"          => "#{surface.width}x#{surface.height}",
  "region_height" => surface.height,
  "changed_lines" => changed_lines,
})
