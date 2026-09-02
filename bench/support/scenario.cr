# Shared scenario logic for all benchmark implementations.
#
# Every implementation calls exactly these functions, so the cell *content*
# produced is identical across termisu, crysterm and the hand-rolled baseline.
# The implementations differ only in *how* they push a cell into their buffer.
module Bench::Scenario
  # A single cell's desired content.
  record Cell,
    ch : Char,
    fr : UInt8, fg_ : UInt8, fb : UInt8,
    br : UInt8, bg_ : UInt8, bb : UInt8

  CHURN_GLYPHS = {' ', '.', ':', '-', '=', '+', '*', '#', '%', '@'}
  BARS         = {' ', '▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'}

  enum Kind
    Churn
    Dashboard
  end

  def self.parse_kind(s : String) : Kind
    case s
    when "churn"     then Kind::Churn
    when "dashboard" then Kind::Dashboard
    else                  raise ArgumentError.new("unknown scenario: #{s}")
    end
  end

  # Content of cell (x, y) on frame `f` of a `w`x`h` screen.
  #
  # Deliberately integer-only: float trig per cell would put the scenario
  # itself on the hot path and blur the thing we are trying to measure
  # (the renderers' output cost).
  def self.cell(kind : Kind, x : Int32, y : Int32, w : Int32, h : Int32, f : Int32) : Cell
    case kind
    in Kind::Churn     then churn(x, y, w, h, f)
    in Kind::Dashboard then dashboard(x, y, w, h, f)
    end
  end

  # Worst case: a scrolling plasma where every cell changes every frame,
  # in TrueColor fg *and* bg. Establishes the throughput ceiling.
  private def self.churn(x, y, w, h, f) : Cell
    v = (x &* 7 &+ y &* 13 &+ f &* 5) & 0xFF
    u = (x &* 3 &- y &* 11 &+ f &* 7) & 0xFF
    Cell.new(
      CHURN_GLYPHS[(v &* CHURN_GLYPHS.size) >> 8],
      (v).to_u8, (255 &- v).to_u8, (u).to_u8,
      (u >> 2).to_u8, (v >> 3).to_u8, ((255 &- u) >> 2).to_u8,
    )
  end

  # Realistic case: a static frame and labels with a live bar chart, a
  # progress bar and a counter. Only a few percent of cells change per frame,
  # so this is where diff rendering has to prove itself. Note that the app
  # still *writes* every cell every frame (immediate-mode style) - suppressing
  # the unchanged ones is precisely the renderer's job.
  private def self.dashboard(x, y, w, h, f) : Cell
    # Outer border
    if y == 0 || y == h - 1 || x == 0 || x == w - 1
      ch = if y == 0 && x == 0
             '┌'
           elsif y == 0 && x == w - 1
             '┐'
           elsif y == h - 1 && x == 0
             '└'
           elsif y == h - 1 && x == w - 1
             '┘'
           elsif y == 0 || y == h - 1
             '─'
           else
             '│'
           end
      return Cell.new(ch, 90_u8, 90_u8, 110_u8, 0_u8, 0_u8, 0_u8)
    end

    # Static title bar
    if y == 1
      title = " anvil bench — dashboard scenario "
      ch = (x - 2) < title.size && x >= 2 ? title[x - 2] : ' '
      return Cell.new(ch, 220_u8, 220_u8, 235_u8, 30_u8, 30_u8, 45_u8)
    end

    # Live counter line: only a handful of cells change per frame
    if y == 3
      label = "frame: #{f}          "
      ch = (x - 2) < label.size && x >= 2 ? label[x - 2] : ' '
      return Cell.new(ch, 160_u8, 200_u8, 160_u8, 0_u8, 0_u8, 0_u8)
    end

    # Progress bar
    if y == 5 && x >= 2 && x < w - 2
      span = w - 4
      filled = ((f % 120) * span) // 120
      inside = x - 2
      return Cell.new('█', 80_u8, 160_u8, 240_u8, 0_u8, 0_u8, 0_u8) if inside < filled
      return Cell.new('░', 50_u8, 50_u8, 70_u8, 0_u8, 0_u8, 0_u8)
    end

    # Scrolling bar chart occupying the lower two thirds
    chart_top = 8
    if y >= chart_top && y < h - 2 && x >= 2 && x < w - 2
      rows = h - 2 - chart_top
      # Integer pseudo-sine: triangle wave, cheap and deterministic
      t = (x &* 5 &+ f &* 3) % 256
      tri = t < 128 ? t : 255 - t # 0..127
      height = (tri &* rows) >> 7 # 0..rows-1
      row_from_bottom = (h - 3) - y
      if row_from_bottom < height
        return Cell.new('█', 60_u8, 180_u8, 200_u8, 0_u8, 0_u8, 0_u8)
      elsif row_from_bottom == height
        frac = ((tri &* rows &* 8) >> 7) & 7
        return Cell.new(BARS[frac], 60_u8, 180_u8, 200_u8, 0_u8, 0_u8, 0_u8)
      else
        return Cell.new(' ', 200_u8, 200_u8, 200_u8, 0_u8, 0_u8, 0_u8)
      end
    end

    Cell.new(' ', 200_u8, 200_u8, 200_u8, 0_u8, 0_u8, 0_u8)
  end
end
