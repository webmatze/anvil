# Same, but requiring skuznetsov/crystal_tui's full framework rather than
# only the buffer files the benchmark uses.
require "crystal_tui"

puts Tui::Buffer.new(1, 1).width
