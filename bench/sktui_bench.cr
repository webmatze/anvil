require "crystal_tui"
require "./support/harness"

# skuznetsov/crystal_tui implementation.
#
# Its widget/CSS layer is skipped for the same reason crysterm's is: we want
# the renderer, not the layout engine. `Tui::Buffer` is its documented-by-code
# double buffer with a per-cell dirty set, and `#flush` is its diff writer -
# the direct counterpart of termisu's `render`.
config = Bench::Config.new("sk_tui")
sync = config.variant != "nosync"

lib LibWinsize
  struct Winsize
    ws_row : LibC::UShort
    ws_col : LibC::UShort
    ws_xpixel : LibC::UShort
    ws_ypixel : LibC::UShort
  end

  fun ioctl(fd : LibC::Int, request : LibC::ULong, ...) : LibC::Int
end

{% if flag?(:darwin) %}
  TIOCGWINSZ = 0x40087468_u64
{% else %}
  TIOCGWINSZ = 0x5413_u64
{% end %}

ws = uninitialized LibWinsize::Winsize
w, h = if LibWinsize.ioctl(1, TIOCGWINSZ, pointerof(ws)) == -1 || ws.ws_col == 0
         {80, 24}
       else
         {ws.ws_col.to_i32, ws.ws_row.to_i32}
       end

IO::FileDescriptor.set_blocking(1, true)
tty = IO::FileDescriptor.new(1)
tty.sync = false

buffer = Tui::Buffer.new(w, h)
stats = Bench::FrameStats.new(config.frames)

style_cache = Hash(UInt64, Tui::Style).new
style_for = ->(fr : UInt8, fg : UInt8, fb : UInt8, br : UInt8, bg : UInt8, bb : UInt8) do
  key = (fr.to_u64 << 40) | (fg.to_u64 << 32) | (fb.to_u64 << 24) |
        (br.to_u64 << 16) | (bg.to_u64 << 8) | bb.to_u64
  style_cache[key] ||= Tui::Style.new(
    fg: Tui::Color.rgb(fr.to_i32, fg.to_i32, fb.to_i32),
    bg: Tui::Color.rgb(br.to_i32, bg.to_i32, bb.to_i32))
end

tty << "\e[?1049h\e[?25l\e[2J"
tty.flush
begin
  stats.begin_run
  interval = config.frame_interval
  next_at = Time.instant
  frame = 0
  while frame < config.frames
    stats.frame_begin
    y = 0
    while y < h
      x = 0
      while x < w
        c = Bench::Scenario.cell(config.scenario, x, y, w, h, frame)
        buffer.set(x, y, Tui::Cell.new(c.ch, style_for.call(c.fr, c.fg_, c.fb, c.br, c.bg_, c.bb)))
        x += 1
      end
      y += 1
    end
    tty << "\e[?2026h" if sync
    buffer.flush(tty)
    tty << "\e[?2026l" if sync
    tty.flush
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
  tty << "\e[0m\e[?25h\e[?1049l"
  tty.flush
end

stats.report(config, {"grid" => "#{w}x#{h}"})
