require "../src/anvil"

# Walks `Anvil::Surface::Inline` through exactly the cases that can go wrong
# in inline rendering: the region grows, the region shrinks, finished lines
# move into the scrollback. `examples/check_inline.py` inspects the resulting
# byte stream automatically; `examples/run_inline.sh` shows it in a terminal.
include Anvil

accent = Text::Style.new(fg: Text::Palette::ACCENT)
dim = Text::Style.new(fg: Text::Palette::MUTED)
ok = Text::Style.new(fg: Text::Palette::SUCCESS)

frames = (ENV["SPIKE_FRAMES"]? || "8").to_i
delay = (ENV["SPIKE_DELAY_MS"]? || "120").to_i.milliseconds

puts "scrollback line A — must stay"
puts "scrollback line B — must stay"

surface = Surface::Inline.new(height: 3)

begin
  frames.times do |i|
    surface.put_line(0, 0, Text.line("── live region, 3 lines ──", accent))
    surface.put_line(0, 1, Text.line("  Frame #{i}", dim))
    surface.put_line(0, 2, Text.line("  #{"▓" * (i % 20)}", accent))
    surface.end_frame
    sleep delay
  end

  surface.height = 6
  frames.times do |i|
    surface.put_line(0, 0, Text.line("── grown to 6 lines ──", accent))
    (1..4).each { |y| surface.put_line(0, y, Text.line("  line #{y}, frame #{i}", dim)) }
    surface.put_line(0, 5, Text.line("  #{"▓" * (i % 20)}", accent))
    surface.end_frame
    sleep delay
  end

  surface.commit([Text.line("✓ committed 1 — must stay in the scrollback", ok),
                  Text.line("✓ committed 2 — must stay in the scrollback", ok)])
  frames.times do |i|
    surface.put_line(0, 0, Text.line("── after commit ──", accent))
    (1..4).each { |y| surface.put_line(0, y, Text.line("  line #{y}, frame #{i}", dim)) }
    surface.put_line(0, 5, Text.line("  #{"▓" * (i % 20)}", accent))
    surface.end_frame
    sleep delay
  end

  surface.height = 2
  frames.times do |i|
    surface.put_line(0, 0, Text.line("── shrunk to 2 lines ──", accent))
    surface.put_line(0, 1, Text.line("  #{"▓" * (i % 20)}", accent))
    surface.end_frame
    sleep delay
  end

  surface.commit([Text.line("✓ committed 3 — last scrollback line", ok)])
ensure
  surface.close
end

puts "demo finished — the scrollback above must be readable in full"
