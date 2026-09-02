require "spec"
require "../src/anvil"

# Tastenereignisse ohne Terminal bauen — die Editor-Specs sollen die Tastatur
# des Entwicklers nicht brauchen.
module KeyFactory
  extend self

  def key(k : Termisu::Input::Key, char : Char? = nil,
          mods : Termisu::Input::Modifier = Termisu::Input::Modifier::None) : Termisu::Event::Key
    Termisu::Event::Key.new(k, mods, char)
  end

  def char(c : Char) : Termisu::Event::Key
    key(Termisu::Input::Key.from_char(c), c)
  end

  # So, wie der Parser es tut: Key-Enum plus Modifier, `char` bleibt leer.
  # Ein Helfer, der hier ein `char` mitgäbe, würde echte Fehler verdecken.
  def ctrl(c : Char) : Termisu::Event::Key
    key(Termisu::Input::Key.from_char(c), nil, Termisu::Input::Modifier::Ctrl)
  end

  def special(k : Termisu::Input::Key) : Termisu::Event::Key
    key(k)
  end

  def type(editor : Anvil::Widgets::InputEditor, text : String) : Nil
    text.each_char { |c| editor.handle(char(c)) }
  end

  # Dieselbe Bequemlichkeit für die App: Tasten gehen durch die
  # Zustandsmaschine statt direkt in den Editor.
  def type(app : Anvil::App, text : String) : Nil
    text.each_char { |c| app.handle_event(char(c)) }
  end
end
