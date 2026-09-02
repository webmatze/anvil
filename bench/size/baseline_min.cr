# The hand-rolled approach has no library to require; this is just a Crystal
# binary that writes ANSI, i.e. the absolute floor for any Crystal TUI.
STDOUT << "\e[?1049h\e[H\e[?1049l"
STDOUT.flush
