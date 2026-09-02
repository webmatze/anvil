require "./spec_helper"

include Anvil
include KeyFactory

# An event source from a list: hands them out in order, then nil (a "poll
# window with no event").
#
# It really waits out the requested time when there is nothing — a real `poll`
# blocks until the timeout, and without imitating that the loop spins in the
# test instead of giving other fibers their chance.
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
  it "draws once at the start and after that only on demand" do
    draws = 0
    l = uninitialized Loop
    l = Loop.new(source([] of Termisu::Event::Any) { |n| l.stop if n >= 3 }, target_fps: 1000)
    l.on_draw { draws += 1 }
    l.run
    draws.should eq 1
  end

  it "does not draw while nothing is dirty" do
    draws = 0
    l = uninitialized Loop
    l = Loop.new(source([] of Termisu::Event::Any) { |n| l.stop if n >= 6 }, target_fps: 1000)
    l.on_draw { draws += 1 }
    l.run
    # The opening frame only: without mark_dirty there is nothing to do.
    draws.should eq 1
  end

  it "draws again after mark_dirty" do
    draws = 0
    l = uninitialized Loop
    events = [KeyFactory.char('x').as(Termisu::Event::Any)]
    l = Loop.new(source(events) { |n| l.stop if n >= 3 }, target_fps: 1000)
    l.on_event { l.mark_dirty }
    l.on_draw { draws += 1 }
    l.run
    draws.should eq 2
  end

  it "debounces resizes: only after several quiet windows" do
    resizes = 0
    quiet_at_first_resize = 0
    l = uninitialized Loop
    events = [Termisu::Event::Resize.new(80, 24).as(Termisu::Event::Any)]
    l = Loop.new(source(events) { |n| l.stop if n >= 8 }, target_fps: 1000)
    l.on_resize { resizes += 1 }
    l.on_draw { }
    l.run
    # Exactly once, not once per WINCH.
    resizes.should eq 1
  end

  it "reports a run of resizes only once" do
    # Dragging a window delivers one WINCH per step; that is what the
    # debounce is for.
    resizes = 0
    l = uninitialized Loop
    events = Array(Termisu::Event::Any).new(5) { Termisu::Event::Resize.new(80, 24) }
    l = Loop.new(source(events) { |n| l.stop if n >= 8 }, target_fps: 1000)
    l.on_resize { resizes += 1 }
    l.on_draw { }
    l.run
    resizes.should eq 1
  end

  it "does not pass a resize on as an ordinary event" do
    # Otherwise every app would handle it twice.
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
