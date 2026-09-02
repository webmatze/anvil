require "./text"

module Anvil::View
  # A piece of content that can draw itself to a given width.
  #
  # Deliberately small: the library supplies the protocol and the lifecycle,
  # the concrete blocks belong to the app. A tool for LLM agents needs
  # different ones than a system monitor, and both are domain.
  abstract class Block
    abstract def lines(width : Int32) : Array(Text::StyledLine)

    # Finished blocks move into the scrollback once and are never drawn again.
    # While this is `false`, the block stays in the live region and is allowed
    # to change.
    def finalized? : Bool
      true
    end
  end

  # A block of ready-made lines — for notices, banners, anything static.
  class TextBlock < Block
    getter source : Array(Text::StyledLine)

    def initialize(@source : Array(Text::StyledLine))
    end

    def self.new(text : String, style : Text::Style = Text::Style::NONE)
      new([Text.line(text, style)])
    end

    def lines(width : Int32) : Array(Text::StyledLine)
      out = Array(Text::StyledLine).new
      @source.each { |l| out.concat(Text.wrap(l, width)) }
      out
    end
  end

  # A section of the live region. `pinned` means: must never be dropped.
  #
  # The status bar and the input line are pinned, running blocks and popups are
  # not — on a screen too small, the input is worth more than the list offering
  # to fill it.
  record Segment, lines : Array(Text::StyledLine), pinned : Bool do
    def self.pinned(lines : Array(Text::StyledLine))
      new(lines, true)
    end

    def self.droppable(lines : Array(Text::StyledLine))
      new(lines, false)
    end
  end

  # Assembles the live region from its sections and trims it to the height
  # available.
  #
  # The region is redrawn in place, which only works while it fits on the
  # screen (see `Surface::Inline#max_height`). When it does not, unpinned lines
  # give way — the oldest first, behind a marker saying how many went.
  module Region
    DEFAULT_MARKER_STYLE = Text::Style.new(fg: Text::Palette::MUTED, dim: true)

    # The default marker standing in for the lines that were dropped.
    def self.default_marker(hidden : Int32) : Text::StyledLine
      Text.line("⋮ #{hidden} more line#{hidden == 1 ? "" : "s"} above", DEFAULT_MARKER_STYLE)
    end

    # `marker` builds the line that stands in for what was dropped — the
    # application decides its wording, the library only that there is one.
    def self.compose(segments : Array(Segment), height : Int32,
                     marker : Proc(Int32, Text::StyledLine)? = nil) : Array(Text::StyledLine)
      budget = height < 1 ? 1 : height
      total = segments.sum { |s| s.lines.size }
      return segments.flat_map(&.lines) if total <= budget

      pinned = segments.sum { |s| s.pinned ? s.lines.size : 0 }
      # The marker costs a line of its own, taken from the room the pinned
      # lines leave behind.
      room = budget - pinned - 1
      room = 0 if room < 0

      hidden = (total - pinned) - room
      remaining = hidden
      marked = false
      region = Array(Text::StyledLine).new

      segments.each do |segment|
        if segment.pinned || remaining <= 0
          region.concat(segment.lines)
          next
        end

        dropped = {remaining, segment.lines.size}.min
        remaining -= dropped
        unless marked
          region << (marker ? marker.call(hidden) : default_marker(hidden))
          marked = true
        end
        region.concat(segment.lines[dropped..]) if dropped < segment.lines.size
      end

      return region if region.size <= budget

      # A screen too small even for the pinned lines. What survives is the
      # *bottom* — status bar and input, without which the user can do nothing.
      # If the region starts with a pinned line (the question everything else
      # refers to), it keeps its row above them: keys answering an unnamed
      # thing are worth less than the question itself.
      head = (first = segments.first?) && first.pinned && !first.lines.empty? ? [first.lines.first] : Array(Text::StyledLine).new
      head = Array(Text::StyledLine).new if head.size >= budget
      keep = budget - head.size
      head + region[(region.size - keep)..]
    end
  end
end
