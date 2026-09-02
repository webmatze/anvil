# Minimal app that pulls in the whole library: the honest binary-size floor.
require "termisu"

t = Termisu.new
t.set_cell(0, 0, 'x')
t.render
t.close
