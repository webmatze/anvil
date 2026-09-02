require "termisu"
require "log"

module Anvil
  # Terminal, input and event loop — the part both modes share.
  #
  # termisu's facade (`Termisu.new`) would do nearly the same, but its
  # constructor unconditionally enters the alternate screen. Inline mode needs
  # exactly not that, and two different event sources for the two modes would
  # be a seam that bites later. So: the same assembly the facade does, with
  # the alternate screen as a switch.
  class Backend
    getter terminal : Termisu::Terminal
    getter? alternate_screen : Bool

    # A terminal type to fall back on when the environment names none.
    #
    # xterm-256color is the safe guess: near-universally understood, and a
    # superset of what this library emits.
    DEFAULT_TERM = "xterm-256color"

    def initialize(*, @alternate_screen : Bool = false, sync_updates : Bool = true)
      silence_library_logs
      # termisu raises when TERM is unset, which turns every container, CI job
      # and cron run into an unhandled exception at startup. A missing TERM is
      # a thin environment, not a broken one, so it gets a default instead.
      ENV["TERM"] = DEFAULT_TERM unless ENV["TERM"]?.presence
      @terminal = Termisu::Terminal.new(sync_updates: sync_updates)
      @reader = Termisu::Reader.new(@terminal.infd)
      @parser = Termisu::Input::Parser.new(@reader)

      @event_loop = Termisu::Event::Loop.new
      @input_source = Termisu::Event::Source::Input.new(@reader, @parser)
      @resize_source = Termisu::Event::Source::Resize.new(-> { @terminal.query_size })
      @event_loop.add_source(@input_source)
      @event_loop.add_source(@resize_source)
      @timer_source = nil.as((Termisu::Event::Source::Timer | Termisu::Event::Source::SystemTimer)?)

      @closed = false
      @terminal.enable_raw_mode
      @event_loop.start
      @terminal.enter_alternate_screen if @alternate_screen
      # Without this, pasted text arrives as a run of individual key presses,
      # indistinguishable from typing — and a multi-line paste then submits
      # once per line.
      @terminal.write("\e[?2004h")
      @terminal.flush

      install_signal_handlers
    end

    # termisu logs through Crystal's `Log`, whose default backend writes to
    # STDERR — straight into our picture as soon as stdout and stderr share a
    # terminal. (The benchmark never noticed, because there stderr goes to a
    # pipe of its own.)
    #
    # Only `termisu*` is silenced, not `*`: the application's logging
    # configuration belongs to the application. Anyone who wants the library's
    # logs sets TERMISU_LOG_LEVEL, and termisu's own setup takes over and
    # writes them to a file.
    private def silence_library_logs : Nil
      if ENV["TERMISU_LOG_LEVEL"]?
        Termisu::Logging.setup
        return
      end

      # Binding an extra null backend does not help: Crystal's bindings add
      # up, so the default STDERR backend would stay. Raising the level on the
      # affected log instances themselves does — it works at the source and
      # leaves the application's logging setup alone.
      Termisu::Log.level = ::Log::Severity::None
      {Termisu::Logs::Terminal, Termisu::Logs::Buffer, Termisu::Logs::Reader,
       Termisu::Logs::Render, Termisu::Logs::Input, Termisu::Logs::Color,
       Termisu::Logs::Terminfo, Termisu::Logs::Event}.each do |log|
        log.level = ::Log::Severity::None
      end
    end

    def size : {Int32, Int32}
      @terminal.size
    end

    def write(data : String) : Nil
      @terminal.write(data)
    end

    def flush : Nil
      @terminal.flush
    end

    # --- events -------------------------------------------------------------

    def poll(timeout : Time::Span) : Termisu::Event::Any?
      select
      when event = @event_loop.output.receive
        prepare(event)
      when timeout(timeout)
        nil
      end
    end

    def try_poll : Termisu::Event::Any?
      select
      when event = @event_loop.output.receive
        prepare(event)
      else
        nil
      end
    end

    # A tick for animation. Without a timer the loop only wakes on real input
    # — which is exactly right for an inline app like smith, since it has
    # nothing to draw while idle.
    def enable_timer(interval : Time::Span, *, kernel : Bool = false) : Nil
      disable_timer
      source = if kernel
                 Termisu::Event::Source::SystemTimer.new(interval)
               else
                 Termisu::Event::Source::Timer.new(interval)
               end
      @event_loop.add_source(source)
      @timer_source = source
    end

    def disable_timer : Nil
      if source = @timer_source
        @event_loop.remove_source(source)
        @timer_source = nil
      end
    end

    private def prepare(event : Termisu::Event::Any) : Termisu::Event::Any
      # The resize has to be through before the caller sees it, or the next
      # draw addresses the old grid.
      if event.is_a?(Termisu::Event::Resize)
        @terminal.query_size
      end
      event
    end

    # --- cleanup ------------------------------------------------------------

    # termisu traps only WINCH: an INT or TERM would leave the terminal in raw
    # mode, with an invisible cursor and possibly in the alternate screen.
    # Measured in the benchmark; closed here.
    private def install_signal_handlers : Nil
      {Signal::INT, Signal::TERM}.each do |sig|
        sig.trap do
          close
          # Re-raise rather than swallow: whoever kills us expects us to die,
          # and the caller should see the right exit code.
          sig.reset
          Process.signal(sig, Process.pid)
        end
      end
      at_exit { close }
    end

    # Idempotent: it runs from the signal handler, from `at_exit` and from a
    # normal exit, and any of those paths can be the first.
    def close : Nil
      return if @closed
      @closed = true

      @event_loop.stop rescue nil
      @terminal.write("\e[?2004l\e[0m\e[?25h") rescue nil
      @terminal.exit_alternate_screen if @alternate_screen rescue nil
      @terminal.flush rescue nil
      @terminal.disable_raw_mode rescue nil
      @reader.close rescue nil
    end

    def closed? : Bool
      @closed
    end
  end
end
