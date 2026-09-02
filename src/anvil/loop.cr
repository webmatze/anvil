require "./backend"
require "./surface"

module Anvil
  # Die Ereignisschleife: Takt, Neuzeichnen und die zwei Feinheiten, die man
  # sonst in jedem Projekt neu lernt — Drift-Korrektur und Resize-Entprellung.
  #
  # Steht getrennt von `App`, damit eine Vollbild-Anwendung sie ohne die
  # Block- und Modal-Maschinerie benutzen kann.
  class Loop
    # Ein Fenster am Rand zu ziehen liefert ein WINCH pro Schritt. Auf jedes
    # davon neu zu zeichnen ist verschwendete Arbeit und sieht wie Flackern
    # aus; stattdessen wird abgewartet, bis so viele Poll-Fenster still
    # geblieben sind.
    RESIZE_SETTLE_TICKS = 3

    property poll_interval : Time::Span
    getter? animating : Bool
    getter? running : Bool

    # Die Ereignisquelle ist ein Proc statt des Backends, damit sich die
    # Schleife ohne Terminal prüfen lässt — Takt und Entprellung sind genau
    # die Logik, die man testen will, und sie hat mit echter Eingabe nichts
    # zu tun.
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

    # Wird gerufen, wenn die Größenänderung zur Ruhe gekommen ist — nicht bei
    # jedem einzelnen WINCH.
    def on_resize(&block : -> Nil) : Nil
      @on_resize = block
    end

    # Ein einzelnes Ereignis abholen, ohne die Schleife zu fahren — für
    # Abfragen, die vor `run` beantwortet werden müssen (ein Vertrauens-
    # Dialog beim Start etwa).
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

    # Die Eingabequelle ist versiegt — ein geschlossenes Terminal, eine
    # abgespielte Skriptdatei. Anders als `stop` ist das eine Aussage über
    # die *Welt*, und alles, was auf eine Taste wartet, muss aufhören zu
    # warten: sonst hängt ein Fiber für immer an einer Frage, die niemand
    # mehr beantworten kann.
    def input_closed! : Nil
      @closed = true
      @stopped = true
    end

    def closed? : Bool
      @closed
    end

    # Im Animationsbetrieb wird jeder Frame gezeichnet, sonst nur wenn etwas
    # als schmutzig gemeldet wurde. Für eine Inline-App ist Letzteres richtig:
    # im Leerlauf gibt es nichts zu zeichnen, und ein Werkzeug, das ohne Grund
    # 60-mal pro Sekunde aufwacht, ist auf einem Laptop unhöflich.
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
          # Fester Zeitschritt statt "jetzt plus Intervall": sonst summiert
          # sich die Zeichenzeit jedes Frames zu einer Drift auf. Liegt der
          # Takt bereits zurück, wird auf jetzt aufgeschlossen, statt eine
          # Aufholjagd zu starten.
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

    # Ein Poll-Fenster ohne Ereignis — daraus besteht "das Ziehen ist vorbei".
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
