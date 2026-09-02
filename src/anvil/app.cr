require "./loop"
require "./view"
require "./surface/inline"
require "./widgets/input_editor"

module Anvil
  # Die Inline-Anwendung: Blocklisten, Live-Region, Eingabezeile und modale
  # Abfragen — das Modell von smith und Claude Code.
  #
  # Fertige Blöcke wandern einmal in den Scrollback; die Region darunter wird
  # neu gezeichnet, solange sich etwas ändert.
  class App
    enum State
      Idle      # am Prompt, der Editor bekommt die Tasten
      Busy      # es läuft etwas, der Nutzer schaut zu
      ModalChar # wartet auf eine aus einer Menge von Tasten
      ModalText # wartet auf eine Zeile Text
      Done
    end

    getter surface : Surface
    getter editor : Widgets::InputEditor
    getter state : State
    getter blocks : Array(View::Block)

    # Die Schleife — für Anwendungen, die den Takt selbst beeinflussen wollen.
    getter loop : Loop

    # Wie die Statuszeile aussieht, entscheidet die App — hier steht nur,
    # dass es eine gibt und dass sie nie weggekürzt wird.
    property status : Proc(Int32, Text::StyledLine)?
    property prompt : Text::StyledLine

    # Popup-Zeilen über der Eingabe, wenn die App eins offen hat.
    property popup : Proc(Int32, Array(Text::StyledLine))?

    # Was mit einer abgesendeten Zeile geschieht. `run` setzt das aus seinem
    # Block; direkt gesetzt lässt sich die App auch ohne Schleife treiben.
    property on_submit : Proc(String, Nil)?

    # Sieht jede Taste vor der Zustandsmaschine. Gibt der Haken `true`
    # zurück, gilt die Taste als verbraucht und die App rührt sie nicht an.
    #
    # Dafür da, dass eine Anwendung Tastenbedeutungen behalten kann, die nur
    # sie kennt — ein offenes Popup, das die Pfeiltasten beansprucht, oder ein
    # Ctrl-C, das erst die Eingabe leert und dann beendet.
    property on_key : Proc(Termisu::Event::Key, Bool)?

    # Nach einer zur Ruhe gekommenen Größenänderung, wenn die Fläche schon
    # nachgeführt und für ungültig erklärt ist. Ob darüber hinaus der ganze
    # Bildschirm gelöscht gehört, weiß nur die Anwendung: das Terminal hat
    # den Scrollback neu umbrochen, und ob das zumutbar ist, hängt davon ab,
    # was dort steht.
    # Der Wortlaut der Marke, die für weggekürzte Zeilen steht.
    property hidden_marker : Proc(Int32, Text::StyledLine)?

    property on_resize : Proc(Nil)?

    property on_interrupt : Proc(Nil)?
    property on_abort : Proc(Nil)?

    DOUBLE_INTERRUPT_WINDOW = 1.second

    def initialize(@surface : Surface, @loop : Loop, *,
                   history : Array(String) = Array(String).new)
      @editor = Widgets::InputEditor.new(history)
      @state = State::Idle
      @blocks = Array(View::Block).new
      @committed = 0
      @prompt = Text.line("> ", Text::Style.new(fg: Text::Palette::ACCENT, bold: true))

      @char_channel = nil.as(Channel(Char)?)
      @text_channel = nil.as(Channel(String)?)
      @modal_keys = Array(Char).new
      @modal_cancel = nil.as(Char?)
      @modal_header = Text::EMPTY_LINE
      @modal_body = Array(Text::StyledLine).new
      @modal_prompt = Text::EMPTY_LINE

      @interrupts = 0
      @last_interrupt = Time.instant
    end

    # --- Inhalt --------------------------------------------------------------

    def add_block(block : View::Block) : View::Block
      @blocks << block
      mark_dirty
      block
    end

    def notice(text : String, style : Text::Style = Text::Style.new(fg: Text::Palette::INFO)) : Nil
      add_block(View::TextBlock.new(text, style))
    end

    def notice(lines : Array(Text::StyledLine)) : Nil
      add_block(View::TextBlock.new(lines))
    end

    def mark_dirty : Nil
      @loop.mark_dirty
    end

    # Alles wegräumen: Blöcke fallen weg, der Bildschirm wird gelöscht. Für
    # ein ausdrückliches "von vorn" der Anwendung.
    def clear! : Nil
      @blocks.clear
      @committed = 0
      @surface.clear_screen
      @surface.invalidate!
      mark_dirty
    end

    def busy! : Nil
      self.state = State::Busy
      mark_dirty
    end

    # Von dem Fiber zu rufen, der die Arbeit gemacht hat: der Prompt kommt
    # zurück.
    def idle! : Nil
      self.state = State::Idle if @state.busy?
      mark_dirty
    end

    def quit : Nil
      self.state = State::Done
      @loop.stop
    end

    # --- Modale Abfragen -----------------------------------------------------

    # Blockiert den *rufenden* Fiber, bis der Nutzer eine der Tasten drückt.
    # Die Tastenschleife läuft derweil weiter — ohne das gäbe es keine
    # Werkzeug-Freigabe mitten in einem laufenden Vorgang.
    # `cancel` gibt an, womit Escape und Ctrl-C beantwortet werden. Ohne das
    # ließe sich eine Frage nur mit einer der angebotenen Tasten verlassen —
    # und "abbrechen" ist bei einer Rückfrage die Erwartung, nicht die
    # Ausnahme.
    def ask(header : Text::StyledLine, body : Array(Text::StyledLine),
            keys : Array(Char), hint : Text::StyledLine, cancel : Char? = nil) : Char
      channel = Channel(Char).new(1)
      @char_channel = channel
      @modal_cancel = cancel
      @modal_keys = keys
      @modal_header = header
      @modal_body = body
      @modal_prompt = hint
      self.state = State::ModalChar
      mark_dirty

      answer = channel.receive
      clear_modal
      answer
    end

    # Dasselbe für eine Zeile Text (Plan-Rückmeldung, freie Antwort).
    def ask_text(header : Text::StyledLine, body : Array(Text::StyledLine)) : String
      channel = Channel(String).new(1)
      @text_channel = channel
      @modal_header = header
      @modal_body = body
      @modal_prompt = @prompt
      self.state = State::ModalText
      @editor.reset
      mark_dirty

      answer = channel.receive
      clear_modal
      answer
    end

    # Wie `ask`, aber mit eigener Tastenschleife — für Fragen, die beantwortet
    # sein müssen, bevor `run` überhaupt anläuft (ein Vertrauens-Dialog beim
    # Start). Blockiert den rufenden Fiber, ohne dass die Hauptschleife läuft.
    def ask_sync(header : Text::StyledLine, body : Array(Text::StyledLine),
                 keys : Array(Char), hint : Text::StyledLine, cancel : Char? = nil) : Char
      saved = {@state, @modal_header, @modal_body, @modal_prompt, @modal_keys, @modal_cancel}
      @modal_cancel = cancel

      @modal_header = header
      @modal_body = body
      @modal_prompt = hint
      @modal_keys = keys
      self.state = State::ModalChar
      render

      answer = cancel || ' '
      until @loop.closed?
        event = @loop.poll(50.milliseconds)
        next unless event.is_a?(Termisu::Event::Key)
        if ch = answer_key(event)
          answer = ch
          break
        end
      end

      restored, @modal_header, @modal_body, @modal_prompt, @modal_keys, @modal_cancel = saved
      self.state = restored
      render
      answer
    end

    # Solange etwas in Arbeit ist, wird durchgehend gezeichnet: Spinner und
    # Laufzeiten bewegen sich von allein, ohne dass jemand sie als schmutzig
    # meldet. Im Leerlauf kostet ein Frame dagegen nichts, weil keiner
    # gezeichnet wird.
    private def state=(value : State) : Nil
      @state = value
      @loop.animating = !value.idle?
    end

    def modal_open? : Bool
      @state.modal_char? || @state.modal_text?
    end

    # Beim Herunterfahren offene Fragen auflösen. Ein Fiber, der an einer
    # `ask` hängt, während die Schleife endet, würde sonst nie zurückkehren.
    private def release_waiters : Nil
      if channel = @char_channel
        @char_channel = nil
        channel.send(@modal_cancel || ' ')
      end
      if channel = @text_channel
        @text_channel = nil
        channel.send("")
      end
    end

    private def clear_modal : Nil
      @char_channel = nil
      @text_channel = nil
      @modal_cancel = nil
      @modal_header = Text::EMPTY_LINE
      @modal_body = Array(Text::StyledLine).new
      @modal_prompt = Text::EMPTY_LINE
      self.state = State::Busy
      mark_dirty
    end

    # --- Schleife ------------------------------------------------------------

    def run(&handler : String -> Nil) : Nil
      @on_submit = handler
      @loop.on_event { |event| handle_event(event) }
      @loop.on_draw { render }
      @loop.on_resize do
        @surface.resized!
        @surface.invalidate!
        @on_resize.try &.call
      end
      begin
        @loop.run
      ensure
        release_waiters
        @surface.close
      end
    end

    # Öffentlich, damit Tests (und Einbettungen) Ereignisse einspeisen können,
    # ohne ein Terminal zu brauchen.
    def handle_event(event : Termisu::Event::Any) : Nil
      return unless event.is_a?(Termisu::Event::Key)

      if filter = @on_key
        if filter.call(event)
          mark_dirty
          return
        end
      end

      # Über der Zustandsmaschine, weil ein verwürfelter Bildschirm am
      # ehesten mitten in einem Vorgang oder unter einem Modal auftritt —
      # genau den zwei Zuständen, die die Taste sonst schlucken würden.
      if event.ctrl? && event.key.to_char == 'l'
        redraw_all!
        return
      end

      if event.ctrl_c?
        interrupt
        return
      end

      case @state
      when State::Idle      then idle_key(event)
      when State::Busy      then nil
      when State::ModalChar then modal_char_key(event)
      when State::ModalText then modal_text_key(event)
      end
      mark_dirty
    end

    private def idle_key(event : Termisu::Event::Key) : Nil
      if submitted = @editor.handle(event)
        return if submitted.strip.empty?
        busy!
        # Auf einem eigenen Fiber, damit die Tastenschleife weiterläuft: nur
        # so kann die Arbeit unterwegs eine modale Frage stellen.
        callback = @on_submit
        spawn do
          callback.try &.call(submitted)
        end
      end
    end

    private def modal_char_key(event : Termisu::Event::Key) : Nil
      channel = @char_channel
      return unless channel
      if ch = answer_key(event)
        channel.send(ch)
      end
    end

    # Der Buchstabe einer Antworttaste, oder nil wenn die Taste nicht zur
    # Auswahl gehört. `char` ist bei gewöhnlichen Zeichen gesetzt; das
    # Key-Enum fängt die Fälle ab, in denen der Parser keins mitgibt.
    private def answer_key(event : Termisu::Event::Key) : Char?
      if cancel = @modal_cancel
        return cancel if event.key.escape? || event.ctrl_c?
      end
      ch = event.char || event.key.to_char
      return nil unless ch
      down = ch.downcase
      @modal_keys.includes?(down) ? down : nil
    end

    private def modal_text_key(event : Termisu::Event::Key) : Nil
      channel = @text_channel
      return unless channel
      if answer = @editor.handle(event)
        channel.send(answer)
      end
    end

    # Ein Ctrl-C bittet um Abbruch, ein zweites kurz darauf beendet.
    private def interrupt : Nil
      now = Time.instant
      @interrupts = (now - @last_interrupt) < DOUBLE_INTERRUPT_WINDOW ? @interrupts + 1 : 1
      @last_interrupt = now

      if @interrupts >= 2
        @on_abort.try &.call
        quit
      else
        @on_interrupt.try &.call
        mark_dirty
      end
    end

    # --- Zeichnen ------------------------------------------------------------

    # Fertige Blöcke einmal in den Scrollback schreiben; danach werden sie nie
    # wieder angefasst.
    private def commit_finished : Nil
      width = @surface.width
      pending = Array(Text::StyledLine).new
      while @committed < @blocks.size && @blocks[@committed].finalized?
        pending << Text::EMPTY_LINE.dup unless @committed == 0 && pending.empty?
        pending.concat(@blocks[@committed].lines(width))
        @committed += 1
      end
      @surface.commit(pending) unless pending.empty?
    end

    # Baut die Live-Region und zeichnet sie. Öffentlich aus demselben Grund.
    def render : Nil
      commit_finished

      width = @surface.width
      lines = View::Region.compose(segments(width), @surface.max_height, @hidden_marker)

      @surface.height = lines.size
      lines.each_with_index { |line, y| @surface.put_line(0, y, line) }
      place_cursor(lines.size)
      @surface.end_frame
    end

    private def segments(width : Int32) : Array(View::Segment)
      out = Array(View::Segment).new

      # Blöcke, die noch laufen: sie stehen in der Region, bis sie fertig sind.
      if @committed < @blocks.size
        live = Array(Text::StyledLine).new
        (@committed...@blocks.size).each_with_index do |i, n|
          live << Text::EMPTY_LINE.dup if n > 0
          live.concat(@blocks[i].lines(width))
        end
        out << View::Segment.droppable(live)
      end

      if modal_open?
        # Die Frage bleibt, der Text den sie beschreibt darf weichen.
        out << View::Segment.pinned([@modal_header]) unless @modal_header.empty?
        out << View::Segment.droppable(@modal_body) unless @modal_body.empty?
        unless @modal_prompt.empty?
          out << View::Segment.droppable([Text::EMPTY_LINE.dup])
          out << View::Segment.pinned([modal_prompt_line(width)])
        end
      end

      out << View::Segment.droppable([Text::EMPTY_LINE.dup]) unless out.empty?

      if popup_proc = @popup
        popup_lines = popup_proc.call(width)
        out << View::Segment.droppable(popup_lines) unless popup_lines.empty?
      end

      tail = Array(Text::StyledLine).new
      if status_proc = @status
        tail << status_proc.call(width)
      end
      tail << input_line(width) if @state.idle?
      out << View::Segment.pinned(tail) unless tail.empty?

      out
    end

    private def input_line(width : Int32) : Text::StyledLine
      field = width - Text.width(@prompt)
      line, _ = @editor.view(field < 1 ? 1 : field)
      @prompt + line
    end

    private def modal_prompt_line(width : Int32) : Text::StyledLine
      return @modal_prompt unless @state.modal_text?
      field = width - Text.width(@modal_prompt)
      line, _ = @editor.view(field < 1 ? 1 : field)
      @modal_prompt + line
    end

    # Der Cursor gehört in die Eingabezeile, wenn eine da ist — sonst weg.
    private def place_cursor(height : Int32) : Nil
      unless @state.idle? || @state.modal_text?
        @surface.hide_cursor
        return
      end

      prefix = @state.modal_text? ? @modal_prompt : @prompt
      field = @surface.width - Text.width(prefix)
      _, col = @editor.view(field < 1 ? 1 : field)
      @surface.cursor_at(Text.width(prefix) + col, height - 1)
    end

    # Bildschirm löschen und den gesamten Verlauf neu ausgeben.
    #
    # Das Zurücksetzen des Commit-Zählers ist der Punkt: ohne das bliebe nach
    # dem Löschen nur die Live-Region übrig und alles bereits Committete wäre
    # vom Bild verschwunden. Gebraucht bei Ctrl-L (etwas hat an uns vorbei
    # geschrieben) und nach einer Größenänderung (das Terminal hat den
    # Scrollback neu umbrochen).
    def redraw_all! : Nil
      @surface.clear_screen
      @committed = 0
      @surface.invalidate!
      mark_dirty
    end
  end
end
