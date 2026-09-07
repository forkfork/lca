local h = require("tests.ui.helper")
local Review = require("agent.ui.review")

h.test("maps single-key review choices", function()
  h.equal(Review.interpret("l"), "like")
  h.equal(Review.interpret("D"), "dislike")
  h.equal(Review.interpret("s"), "skip")
  h.equal(Review.interpret("q"), "quit")
  h.equal(Review.interpret("x"), nil)
end)

h.finish()
