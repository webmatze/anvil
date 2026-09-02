require "./support/harness"

# Hand-rolled fullscreen renderer: no framework, no dependencies.
#
# This is the control group. It does the minimum a 60fps TUI needs -
# a front/back cell buffer, a per-cell diff, one buffered write plus one
# flush per frame, alt screen, hidden cursor and DEC 2026 synchronized
# output - and nothing else. Whatever it achieves is the ceiling; the
# frameworks are worth their cost only if they come close to it.
module Bench::Baseline
  struct Cell
    property ch : Char
    property fr : UInt8
    property fg : UInt8
    property fb : UInt8
    property br : UInt8
    property bg : UInt8
    property bb : UInt8

    def initialize(@ch = ' ', @fr = 0_u8, @fg = 0_u8, @fb = 0_u8, @br = 0_u8, @bg = 0_u8, @bb = 0_u8)
    end

    def ==(o : Cell)
      @ch == o.ch && @fr == o.fr && @fg == o.fg && @fb == o.fb &&
        @br == o.br && @bg == o.bg && @bb == o.bb
    end
  end

  class Screen
    getter width : Int32
    getter height : Int32

    def initialize(@width, @height, @io : IO)
      size = @width * @height
      @front = Array(Cell).new(size) { Cell.new }
      @back = Array(Cell).new(size) { Cell.new }
      # One reusable frame buffer: the per-frame escape stream is assembled
      # here and handed to the terminal in a single write.
      @out = IO::Memory.new(256 * 1024)
    end

    def set(x : Int32, y : Int32, c : Cell) : Nil
      @back.unsafe_put(y * @width + x, c)
    end

    def start : Nil
      @io << "\e[?1049h\e[?25l\e[2J"
      @io.flush
    end

    def finish : Nil
      @io << "\e[0m\e[?25h\e[?1049l"
      @io.flush
    end

    # Emits only the cells that differ from what the terminal already shows.
    # Returns the number of cells actually written.
    def render(sync : Bool) : Int32
      @out.clear
      @out << "\e[?2026h" if sync

      changed = 0
      # Cursor and SGR state are tracked across the whole frame so runs of
      # adjacent changed cells with the same colors cost one byte each.
      cur_x = -1
      cur_y = -1
      last_fr = -1; last_fg = -1; last_fb = -1
      last_br = -1; last_bg = -1; last_bb = -1

      y = 0
      while y < @height
        x = 0
        row = y * @width
        while x < @width
          i = row + x
          nc = @back.unsafe_fetch(i)
          if nc != @front.unsafe_fetch(i)
            unless cur_y == y && cur_x == x
              @out << "\e[" << (y + 1) << ';' << (x + 1) << 'H'
              cur_x = x; cur_y = y
            end
            if nc.fr.to_i != last_fr || nc.fg.to_i != last_fg || nc.fb.to_i != last_fb
              @out << "\e[38;2;" << nc.fr << ';' << nc.fg << ';' << nc.fb << 'm'
              last_fr = nc.fr.to_i; last_fg = nc.fg.to_i; last_fb = nc.fb.to_i
            end
            if nc.br.to_i != last_br || nc.bg.to_i != last_bg || nc.bb.to_i != last_bb
              @out << "\e[48;2;" << nc.br << ';' << nc.bg << ';' << nc.bb << 'm'
              last_br = nc.br.to_i; last_bg = nc.bg.to_i; last_bb = nc.bb.to_i
            end
            @out << nc.ch
            cur_x = x + 1
            @front.unsafe_put(i, nc)
            changed += 1
          end
          x += 1
        end
        y += 1
      end

      @out << "\e[?2026l" if sync
      @io.write @out.to_slice
      @io.flush
      changed
    end
  end
end

config = Bench::Config.new("baseline")
sync = config.variant != "nosync"

# Terminal size straight from the ioctl, same source the frameworks use.
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

def term_size : {Int32, Int32}
  ws = uninitialized LibWinsize::Winsize
  if LibWinsize.ioctl(1, TIOCGWINSZ, pointerof(ws)) == -1 || ws.ws_col == 0
    {80, 24}
  else
    {ws.ws_col.to_i32, ws.ws_row.to_i32}
  end
end

w, h = term_size
IO::FileDescriptor.set_blocking(1, true)
tty = IO::FileDescriptor.new(1)
tty.sync = false
screen = Bench::Baseline::Screen.new(w, h, tty)
stats = Bench::FrameStats.new(config.frames)
changed_total = 0_i64

screen.start
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
        screen.set(x, y, Bench::Baseline::Cell.new(c.ch, c.fr, c.fg_, c.fb, c.br, c.bg_, c.bb))
        x += 1
      end
      y += 1
    end
    changed_total += screen.render(sync)
    stats.frame_end

    # Fixed timestep: sleep to the next slot, never accumulate drift.
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
  screen.finish
end

stats.report(config, {"cells_changed_per_frame" => changed_total / config.frames.to_f, "grid" => "#{w}x#{h}"})
