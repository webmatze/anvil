require "spec"
require "../src/anvil"

# Build key events without a terminal — the editor specs should not need the
# developer's keyboard.
module KeyFactory
  extend self

  def key(k : Termisu::Input::Key, char : Char? = nil,
          mods : Termisu::Input::Modifier = Termisu::Input::Modifier::None) : Termisu::Event::Key
    Termisu::Event::Key.new(k, mods, char)
  end

  def char(c : Char) : Termisu::Event::Key
    key(Termisu::Input::Key.from_char(c), c)
  end

  # The way the parser does it: key enum plus modifier, `char` left empty. A
  # helper that supplied a `char` here would hide real bugs.
  def ctrl(c : Char) : Termisu::Event::Key
    key(Termisu::Input::Key.from_char(c), nil, Termisu::Input::Modifier::Ctrl)
  end

  def special(k : Termisu::Input::Key) : Termisu::Event::Key
    key(k)
  end

  def type(editor : Anvil::Widgets::InputEditor, text : String) : Nil
    text.each_char { |c| editor.handle(char(c)) }
  end

  # The same convenience for the app: keys go through the state machine rather
  # than straight into the editor.
  def type(app : Anvil::App, text : String) : Nil
    text.each_char { |c| app.handle_event(char(c)) }
  end
end
