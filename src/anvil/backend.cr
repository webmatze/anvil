require "termisu"
require "log"

module Anvil
  # Terminal, Eingabe und Ereignisschleife — der Teil, den sich beide
  # Betriebsarten teilen.
  #
  # termisus Fassade (`Termisu.new`) täte fast dasselbe, betritt aber im
  # Konstruktor bedingungslos den Alternate Screen. Der Inline-Modus braucht
  # genau das nicht, und zwei verschiedene Ereignisquellen für die zwei
  # Betriebsarten wären eine Naht, die sich später rächt. Also derselbe
  # Aufbau wie in der Fassade, nur mit dem Alt-Screen als Schalter.
  class Backend
    getter terminal : Termisu::Terminal
    getter? alternate_screen : Bool

    def initialize(*, @alternate_screen : Bool = false, sync_updates : Bool = true)
      silence_library_logs
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
      # Ohne das kommt eingefügter Text als Folge einzelner Tastendrücke an,
      # nicht unterscheidbar von getipptem — und mehrzeiliges Einfügen löst
      # dann pro Zeile ein Absenden aus.
      @terminal.write("\e[?2004h")
      @terminal.flush

      install_signal_handlers
    end

    # termisu protokolliert über Crystals `Log`, und dessen Standard-Backend
    # schreibt nach STDERR — also mitten in unser Bild, sobald stdout und
    # stderr dasselbe Terminal sind. (Im Benchmark fiel das nicht auf, weil
    # dort stderr in eine eigene Pipe geht.)
    #
    # Stummgeschaltet wird gezielt nur `termisu*`, nicht `*`: die Log-Konfiguration
    # der Anwendung gehört der Anwendung. Wer die Bibliotheksprotokolle sehen
    # will, setzt TERMISU_LOG_LEVEL — dann übernimmt termisus eigene
    # Einrichtung und schreibt in eine Datei.
    private def silence_library_logs : Nil
      if ENV["TERMISU_LOG_LEVEL"]?
        Termisu::Logging.setup
        return
      end

      # Ein zusätzliches Null-Backend zu binden hilft nicht: Crystals
      # Bindungen addieren sich, das voreingestellte STDERR-Backend bliebe
      # bestehen. Stattdessen wird die Schwelle der betroffenen Log-Instanzen
      # selbst hochgesetzt — das wirkt an der Quelle und lässt die
      # Log-Einrichtung der Anwendung unangetastet.
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

    # --- Ereignisse ---------------------------------------------------------

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

    # Ein Takt für Animationen. Ohne Timer wird nur bei echter Eingabe
    # geweckt — für eine Inline-App wie smith ist genau das richtig, weil sie
    # im Leerlauf nichts zu zeichnen hat.
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
      # Die Größenänderung muss durch sein, bevor der Aufrufer sie sieht —
      # sonst adressiert der nächste Zeichenvorgang das alte Raster.
      if event.is_a?(Termisu::Event::Resize)
        @terminal.query_size
      end
      event
    end

    # --- Aufräumen ----------------------------------------------------------

    # termisu trappt nur WINCH: ein INT oder TERM ließe das Terminal im
    # Raw-Mode zurück, mit unsichtbarem Cursor und ggf. im Alt-Screen. Im
    # Benchmark nachgemessen; hier geschlossen.
    private def install_signal_handlers : Nil
      {Signal::INT, Signal::TERM}.each do |sig|
        sig.trap do
          close
          # Weitergeben statt schlucken: wer uns abschießt, erwartet, dass
          # wir sterben — und der Aufrufer soll den richtigen Exit-Code sehen.
          sig.reset
          Process.signal(sig, Process.pid)
        end
      end
      at_exit { close }
    end

    # Idempotent: läuft aus dem Signal-Handler, aus `at_exit` und aus dem
    # regulären Ende, und jeder dieser Wege kann der erste sein.
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
