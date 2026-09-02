require "crysterm"

w = Crysterm::Window.new
Crysterm::Widgets::Box.new parent: w, width: "100%", height: "100%"
w.after(1.milliseconds) { w.quit }
w.exec
