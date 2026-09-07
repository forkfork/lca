local ansi = {}

ansi.ESC = "\27["

function ansi.move_up(rows)
  return rows > 0 and (ansi.ESC .. tostring(rows) .. "A") or ""
end

function ansi.move_down(rows)
  return rows > 0 and (ansi.ESC .. tostring(rows) .. "B") or ""
end

function ansi.move_right(cols)
  return cols > 0 and (ansi.ESC .. tostring(cols) .. "C") or ""
end

function ansi.move_left(cols)
  return cols > 0 and (ansi.ESC .. tostring(cols) .. "D") or ""
end

function ansi.position(row, col)
  return ansi.ESC .. tostring(row) .. ";" .. tostring(col) .. "H"
end

ansi.carriage_return = "\r"
ansi.clear_line = ansi.ESC .. "2K"
ansi.clear_to_end = ansi.ESC .. "K"
ansi.clear_screen = ansi.ESC .. "2J"
ansi.hide_cursor = ansi.ESC .. "?25l"
ansi.show_cursor = ansi.ESC .. "?25h"
ansi.enter_alt_screen = ansi.ESC .. "?1049h"
ansi.leave_alt_screen = ansi.ESC .. "?1049l"
ansi.enable_bracketed_paste = ansi.ESC .. "?2004h"
ansi.disable_bracketed_paste = ansi.ESC .. "?2004l"
ansi.begin_synchronized_update = ansi.ESC .. "?2026h"
ansi.end_synchronized_update = ansi.ESC .. "?2026l"
ansi.reset = ansi.ESC .. "0m"

return ansi
