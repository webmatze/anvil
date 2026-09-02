require "./backend"
require "./surface"

module Anvil
  # The event loop: tick, redraw, and the two subtleties one otherwise learns
  # again in every project — drift correction and resize debouncing.
  #
  # Kept separate from `App` so that a fullscreen application can use it
  # without the block and modal machinery.
  class Loop
    # Dragging a window edge delivers one WINCH per step. Redrawing on each of
    # them is wasted work and reads as flicker; instead the redraw waits until
    # this many poll windows have stayed quiet.
    RESIZE_SETTLE_TICKS = 3

    property poll_interval : Time::Span
    getter? animating : Bool
    getter? running : Bool

    # The event source is a Proc rather than the backend so the loop can be
    # checked without a terminal — tick and debounce are exactly the logic
    # worth testing, and neither has anything to do with real input.
    def self.for(backend : Backend, **options) : Loop
      new(->(timeout : Time::Span) { backend.poll(timeout) }, **options)
    end

    def initialize(@poll : Proc(Time::Span, Termisu::Event::Any?), *, target_fps : Int32 = 60,
                   @animating : Bool = false, poll_interval : Time::Span = 50.milliseconds)
      @frame_interval = (1.0 / target_fps).seconds
      @poll_interval = poll_interval
      @dirty = true
      @running = false
      @stopped = false
      @closed = false
      @resize_quiet = 0
      @on_event = nil.as(Proc(Termisu::Event::Any, Nil)?)
      @on_draw = nil.as(Proc(Nil)?)
      @on_resize = nil.as(Proc(Nil)?)
    end

    def on_event(&block : Termisu::Event::Any -> Nil) : Nil
      @on_event = block
    end

    def on_draw(&block : -> Nil) : Nil
      @on_draw = block
    end

    # Called once a resize has settled — not on every individual WINCH.
    def on_resize(&block : -> Nil) : Nil
      @on_resize = block
    end

    # Fetch a single event without running the loop — for questions that must
    # be answered before `run` starts (a trust prompt at startup, say).
    def poll(timeout : Time::Span) : Termisu::Event::Any?
      @poll.call(timeout)
    end

    def mark_dirty : Nil
      @dirty = true
    end

    def dirty? : Bool
      @dirty
    end

    def stop : Nil
      @stopped = true
    end

    # The input source has run dry — a closed terminal, a script played to its
    # end. Unlike `stop` this is a statement about the *world*, and everything
    # waiting on a key has to stop waiting: otherwise a fiber hangs forever on
    # a question nobody can answer any more.
    def input_closed! : Nil
      @closed = true
      @stopped = true
    end

    def closed? : Bool
      @closed
    end

    # While animating, every frame is drawn; otherwise only when something
    # reported itself dirty. The latter is right for an inline app: there is
    # nothing to draw while idle, and a tool that wakes 60 times a second for
    # no reason is rude on a laptop.
    def animating=(value : Bool) : Nil
      @animating = value
      @dirty = true if value
    end

    def run : Nil
      @running = true
      @stopped = false
      next_frame = Time.instant
      draw

      until @stopped
        timeout = if @animating
                    remaining = next_frame - Time.instant
                    remaining > Time::Span.zero ? remaining : Time::Span.zero
                  else
                    @poll_interval
                  end

        if event = @poll.call(timeout)
          handle(event)
        else
          quiet_tick
        end

        now = Time.instant
        if (@animating || @dirty) && now >= next_frame
          draw
          # A fixed timestep rather than "now plus interval": otherwise each
          # frame's drawing time accumulates into drift. When the tick is
          # already behind, catch up to now instead of starting a chase.
          next_frame += @frame_interval
          next_frame = now if next_frame < now
        end
      end
    ensure
      @running = false
    end

    private def handle(event : Termisu::Event::Any) : Nil
      if event.is_a?(Termisu::Event::Resize)
        @resize_quiet = RESIZE_SETTLE_TICKS
        return
      end
      @on_event.try &.call(event)
    end

    # A poll window with no event — what "the drag is over" is made of.
    private def quiet_tick : Nil
      return if @resize_quiet == 0
      @resize_quiet -= 1
      return unless @resize_quiet == 0
      @on_resize.try &.call
      @dirty = true
    end

    private def draw : Nil
      @dirty = false
      @on_draw.try &.call
    end
  end
end
