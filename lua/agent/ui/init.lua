return {
  ansi = require("agent.ui.ansi"),
  Buffer = require("agent.ui.buffer"),
  Current = require("agent.ui.current"),
  kinetic = require("agent.ui.kinetic"),
  Review = require("agent.ui.review"),
  Renderer = require("agent.ui.renderer"),
  style = require("agent.ui.style"),
  Terminal = require("agent.ui.terminal"),
  width = require("agent.ui.width"),
  backends = {
    posix = require("agent.ui.backends.posix"),
  },
}
