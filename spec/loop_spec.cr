require "./spec_helper"

include Anvil
include KeyFactory

# Eine Ereignisquelle aus einer Liste: liefert der Reihe nach, danach nil
# (also "Poll-Fenster ohne Ereignis").
#
# Wartet die angefragte Zeit tatsächlich ab, wenn nichts da ist — ein echtes
# `poll` blockiert bis zum Timeout, und ohne dieses Nachstellen dreht die
# Schleife im Test leer, statt anderen Fibern die Gelegenheit zu geben.
private def source(events : Array(Termisu::Event::Any), *, quiet_limit : Int32 = 8, &on_quiet : Int32 -> Nil)
  queue = events.dup
  quiet = 0
  ->(timeout : Time::Span) do
    if event = queue.shift?
      event
    else
      quiet += 1
      on_quiet.call(quiet)
      sleep timeout.total_seconds > 0.005 ? 0.005.seconds : timeout
      nil.as(Termisu::Event::Any?)
    end
  end
end

describe Anvil::Loop do
  it "zeichnet einmal zu Beginn und danach nur bei Bedarf" do
    draws = 0
    l = uninitialized Loop
    l = Loop.new(source([] of Termisu::Event::Any) { |n| l.stop if n >= 3 }, target_fps: 1000)
    l.on_draw { draws += 1 }
    l.run
    draws.should eq 1
  end

  it "zeichnet nicht, solange nichts schmutzig ist" do
    draws = 0
    l = uninitialized Loop
    l = Loop.new(source([] of Termisu::Event::Any) { |n| l.stop if n >= 6 }, target_fps: 1000)
    l.on_draw { draws += 1 }
    l.run
    # Nur der Eröffnungsframe: ohne mark_dirty gibt es nichts zu tun.
    draws.should eq 1
  end

  it "zeichnet nach mark_dirty erneut" do
    draws = 0
    l = uninitialized Loop
    events = [KeyFactory.char('x').as(Termisu::Event::Any)]
    l = Loop.new(source(events) { |n| l.stop if n >= 3 }, target_fps: 1000)
    l.on_event { l.mark_dirty }
    l.on_draw { draws += 1 }
    l.run
    draws.should eq 2
  end

  it "entprellt Größenänderungen: erst nach mehreren stillen Fenstern" do
    resizes = 0
    quiet_at_first_resize = 0
    l = uninitialized Loop
    events = [Termisu::Event::Resize.new(80, 24).as(Termisu::Event::Any)]
    l = Loop.new(source(events) { |n| l.stop if n >= 8 }, target_fps: 1000)
    l.on_resize { resizes += 1 }
    l.on_draw { }
    l.run
    # Genau einmal, nicht einmal je WINCH.
    resizes.should eq 1
  end

  it "meldet mehrere Größenänderungen in Folge nur einmal" do
    # Ein Fenster zu ziehen liefert ein WINCH pro Schritt; genau dafür ist
    # die Entprellung da.
    resizes = 0
    l = uninitialized Loop
    events = Array(Termisu::Event::Any).new(5) { Termisu::Event::Resize.new(80, 24) }
    l = Loop.new(source(events) { |n| l.stop if n >= 8 }, target_fps: 1000)
    l.on_resize { resizes += 1 }
    l.on_draw { }
    l.run
    resizes.should eq 1
  end

  it "meldet eine Größenänderung nicht als gewöhnliches Ereignis weiter" do
    # Sonst würde jede App sie doppelt behandeln.
    seen = 0
    l = uninitialized Loop
    events = [Termisu::Event::Resize.new(80, 24).as(Termisu::Event::Any)]
    l = Loop.new(source(events) { |n| l.stop if n >= 6 }, target_fps: 1000)
    l.on_event { seen += 1 }
    l.on_draw { }
    l.run
    seen.should eq 0
  end
end
