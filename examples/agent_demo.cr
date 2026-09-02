require "../src/anvil"

# Eine vollständige Inline-App im Zuschnitt von smith: Eingabezeile,
# Statusleiste, streamende Blöcke, eine modale Rückfrage mitten in der Arbeit
# und fertige Ergebnisse, die in den Scrollback wandern.
#
# Gedacht zum Ausprobieren im echten Terminal:
#   crystal run examples/agent_demo.cr
#
# Eingaben: irgendein Text startet einen "Vorgang". "gefahr" löst die modale
# Rückfrage aus. "quit" beendet, Ctrl-C zweimal auch.
include Anvil

# Ein Block, der noch wächst — wie streamender Text vom Modell.
class StreamBlock < View::Block
  property text : String
  property? done = false

  def initialize(@label : String, @text : String = "")
  end

  def finalized? : Bool
    @done
  end

  def lines(width : Int32) : Array(Text::StyledLine)
    head = Text.line(@label, Text::Style.new(fg: Text::Palette::ACCENT, bold: true))
    body = Text.wrap(Text.line(@text), width)
    body.empty? ? [head] : ([head] + body)
  end
end

# Ein Werkzeugaufruf mit Zustand — das klassische "läuft / fertig / Fehler".
class ToolBlock < View::Block
  enum Status
    Running
    Done
    Failed
  end

  property status : Status = Status::Running

  def initialize(@name : String, @summary : String)
    @started = Time.instant
  end

  def finalized? : Bool
    !@status.running?
  end

  def lines(width : Int32) : Array(Text::StyledLine)
    marker, style = case @status
                    in Status::Running then {"◐", Text::Style.new(fg: Text::Palette::WARN)}
                    in Status::Done    then {"✓", Text::Style.new(fg: Text::Palette::SUCCESS)}
                    in Status::Failed  then {"✗", Text::Style.new(fg: Text::Palette::ERROR)}
                    end
    line = Text::StyledLine.new
    line << Text::Span.new("#{marker} ", style)
    line << Text::Span.new(@name, Text::Style.new(bold: true))
    line << Text::Span.new(" #{@summary}", Text::Style.new(fg: Text::Palette::MUTED))
    unless @status.running?
      line << Text::Span.new(" (#{(Time.instant - @started).total_milliseconds.round}ms)",
        Text::Style.new(fg: Text::Palette::MUTED, dim: true))
    end
    [Text.truncate(line, width, "…")]
  end
end

backend = Backend.new(alternate_screen: false)
surface = Surface::Inline.new(backend, height: 1)
# 20 fps genügen: gezeichnet wird ohnehin nur, wenn sich etwas geändert hat.
app = App.new(surface, Loop.for(backend, target_fps: 20))

activity = ""
turns = 0

app.status = ->(width : Int32) do
  left = activity.empty? ? "bereit" : activity
  right = "#{turns} Vorgänge · Ctrl-C zum Beenden"
  gap = width - Text.width(left) - Text.width(right)
  gap = 1 if gap < 1
  line = Text::StyledLine.new
  line << Text::Span.new(left, Text::Style.new(fg: Text::Palette::ACCENT))
  line << Text::Span.new(" " * gap)
  line << Text::Span.new(right, Text::Style.new(fg: Text::Palette::MUTED, dim: true))
  Text.truncate(line, width)
end

app.on_interrupt = -> do
  app.notice("⚠ nochmal Ctrl-C zum Beenden", Text::Style.new(fg: Text::Palette::WARN))
  nil
end

app.notice([
  Text.line("⚒ anvil — Inline-Demo", Text::Style.new(bold: true)),
  Text.line("Text eingeben startet einen Vorgang · \"gefahr\" fragt nach · \"quit\" beendet",
    Text::Style.new(fg: Text::Palette::MUTED, dim: true)),
])

app.run do |input|
  turns += 1

  if input == "quit"
    app.quit
    next
  end

  app.add_block(View::TextBlock.new("❯ #{input}", Text::Style.new(fg: Text::Palette::MUTED)))

  activity = "denkt nach…"
  stream = app.add_block(StreamBlock.new("✻ Antwort")).as(StreamBlock)
  "Das ist eine streamende Antwort, die Wort für Wort ankommt und dabei umbricht, wenn das Fenster schmal ist. ".split(' ').each do |word|
    stream.text += "#{word} "
    app.mark_dirty
    sleep 40.milliseconds
  end
  stream.done = true

  tool = app.add_block(ToolBlock.new("Bash", "ls -la")).as(ToolBlock)
  activity = "führt aus…"
  app.mark_dirty
  sleep 400.milliseconds

  # Die modale Rückfrage läuft auf diesem Fiber; die Tastenschleife bleibt
  # derweil bedienbar. Genau das braucht eine Werkzeug-Freigabe.
  if input.includes?("gefahr")
    answer = app.ask(
      Text.line("Wirklich ausführen?", Text::Style.new(bold: true, fg: Text::Palette::WARN)),
      [Text.line("  rm -rf /tmp/beispiel", Text::Style.new(fg: Text::Palette::MUTED))],
      ['j', 'n'],
      Text.line("[j] ja  [n] nein", Text::Style.new(fg: Text::Palette::ACCENT)))
    tool.status = answer == 'j' ? ToolBlock::Status::Done : ToolBlock::Status::Failed
    app.notice(answer == 'j' ? "ausgeführt" : "abgelehnt",
      Text::Style.new(fg: answer == 'j' ? Text::Palette::SUCCESS : Text::Palette::MUTED))
  else
    tool.status = ToolBlock::Status::Done
  end

  activity = ""
  app.idle!
end
