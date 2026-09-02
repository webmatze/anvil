require "../src/anvil"

# A complete inline app in the shape of smith: input line, status bar,
# streaming blocks, a modal question asked in the middle of the work, and
# finished results moving into the scrollback.
#
# Meant to be tried in a real terminal:
#   crystal run examples/agent_demo.cr
#
# Input: any text starts a "turn". "danger" triggers the modal question.
# "quit" ends it, as does Ctrl-C twice.
include Anvil

# A block that is still growing — like text streaming from a model.
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

# A tool call with state — the classic "running / done / failed".
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
# 20 fps is plenty: a frame is only drawn when something changed anyway.
app = App.new(surface, Loop.for(backend, target_fps: 20))

activity = ""
turns = 0

app.status = ->(width : Int32) do
  left = activity.empty? ? "ready" : activity
  right = "#{turns} turns · Ctrl-C to quit"
  gap = width - Text.width(left) - Text.width(right)
  gap = 1 if gap < 1
  line = Text::StyledLine.new
  line << Text::Span.new(left, Text::Style.new(fg: Text::Palette::ACCENT))
  line << Text::Span.new(" " * gap)
  line << Text::Span.new(right, Text::Style.new(fg: Text::Palette::MUTED, dim: true))
  Text.truncate(line, width)
end

app.on_interrupt = -> do
  app.notice("⚠ Ctrl-C again to quit", Text::Style.new(fg: Text::Palette::WARN))
  nil
end

app.notice([
  Text.line("⚒ anvil — inline demo", Text::Style.new(bold: true)),
  Text.line("type anything to start a turn · \"danger\" asks first · \"quit\" ends it",
    Text::Style.new(fg: Text::Palette::MUTED, dim: true)),
])

app.run do |input|
  turns += 1

  if input == "quit"
    app.quit
    next
  end

  app.add_block(View::TextBlock.new("❯ #{input}", Text::Style.new(fg: Text::Palette::MUTED)))

  activity = "thinking…"
  stream = app.add_block(StreamBlock.new("✻ Answer")).as(StreamBlock)
  "This is a streaming answer that arrives word by word and wraps when the window is narrow. ".split(' ').each do |word|
    stream.text += "#{word} "
    app.mark_dirty
    sleep 40.milliseconds
  end
  stream.done = true

  tool = app.add_block(ToolBlock.new("Bash", "ls -la")).as(ToolBlock)
  activity = "running…"
  app.mark_dirty
  sleep 400.milliseconds

  # The modal question runs on this fiber while the key loop stays usable.
  # That is exactly what a tool approval needs.
  if input.includes?("danger")
    answer = app.ask(
      Text.line("Really run this?", Text::Style.new(bold: true, fg: Text::Palette::WARN)),
      [Text.line("  rm -rf /tmp/example", Text::Style.new(fg: Text::Palette::MUTED))],
      ['y', 'n'],
      Text.line("[y] yes  [n] no", Text::Style.new(fg: Text::Palette::ACCENT)))
    tool.status = answer == 'y' ? ToolBlock::Status::Done : ToolBlock::Status::Failed
    app.notice(answer == 'y' ? "ran it" : "declined",
      Text::Style.new(fg: answer == 'y' ? Text::Palette::SUCCESS : Text::Palette::MUTED))
  else
    tool.status = ToolBlock::Status::Done
  end

  activity = ""
  app.idle!
end
