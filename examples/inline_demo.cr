require "../src/anvil"

# Führt `Anvil::Surface::Inline` durch genau die Fälle vor, die beim
# Inline-Rendering schiefgehen können: Region wächst, Region schrumpft,
# fertige Zeilen wandern in den Scrollback. `spike/check.py` prüft die
# erzeugte Byte-Folge automatisch, `spike/run.sh` zeigt es im Terminal.
include Anvil

accent = Text::Style.new(fg: Text::Palette::ACCENT)
dim = Text::Style.new(fg: Text::Palette::MUTED)
ok = Text::Style.new(fg: Text::Palette::SUCCESS)

frames = (ENV["SPIKE_FRAMES"]? || "8").to_i
delay = (ENV["SPIKE_DELAY_MS"]? || "120").to_i.milliseconds

puts "Scrollback-Zeile A — muss stehen bleiben"
puts "Scrollback-Zeile B — muss stehen bleiben"

surface = Surface::Inline.new(height: 3)

begin
  frames.times do |i|
    surface.put_line(0, 0, Text.line("── Live-Region, 3 Zeilen ──", accent))
    surface.put_line(0, 1, Text.line("  Frame #{i}", dim))
    surface.put_line(0, 2, Text.line("  #{"▓" * (i % 20)}", accent))
    surface.end_frame
    sleep delay
  end

  surface.height = 6
  frames.times do |i|
    surface.put_line(0, 0, Text.line("── gewachsen auf 6 Zeilen ──", accent))
    (1..4).each { |y| surface.put_line(0, y, Text.line("  Zeile #{y}, Frame #{i}", dim)) }
    surface.put_line(0, 5, Text.line("  #{"▓" * (i % 20)}", accent))
    surface.end_frame
    sleep delay
  end

  surface.commit([Text.line("✓ committed 1 — muss im Scrollback bleiben", ok),
                  Text.line("✓ committed 2 — muss im Scrollback bleiben", ok)])
  frames.times do |i|
    surface.put_line(0, 0, Text.line("── nach commit ──", accent))
    (1..4).each { |y| surface.put_line(0, y, Text.line("  Zeile #{y}, Frame #{i}", dim)) }
    surface.put_line(0, 5, Text.line("  #{"▓" * (i % 20)}", accent))
    surface.end_frame
    sleep delay
  end

  surface.height = 2
  frames.times do |i|
    surface.put_line(0, 0, Text.line("── geschrumpft auf 2 Zeilen ──", accent))
    surface.put_line(0, 1, Text.line("  #{"▓" * (i % 20)}", accent))
    surface.end_frame
    sleep delay
  end

  surface.commit([Text.line("✓ committed 3 — letzte Scrollback-Zeile", ok)])
ensure
  surface.close
end

puts "Spike beendet — Scrollback oberhalb muss vollständig lesbar sein"
