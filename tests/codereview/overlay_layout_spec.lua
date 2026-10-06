-- Where the **overlay**'s cards start in the **margin**, as data: anchor rows and card
-- heights in, start rows out.
--
-- No window anywhere in this file. The margin spec beside it proves the rows reach the
-- screen; this one states the rules a reviewer reads off the margin -- stacking, the cut at
-- the bottom, the card whose anchor is out of view, the pinned whole-file card -- where a
-- screen cannot hide an off-by-one behind a coincidence of fixture heights.
local overlay = require("codereview.overlay")

describe("the overlay's layout", function()
  it("lays out nothing for no cards", function()
    assert.same({}, overlay.layout({}, 20))
  end)

  it("starts a card on its anchor's row when nothing is above it", function()
    assert.same({ { start = 5, rows = 3 } }, overlay.layout({ { row = 5, height = 3 } }, 20))
  end)

  -- Anchors one row apart, the first card three rows tall: the second would start inside
  -- the first, so it starts on the row after the first ends.
  it("pushes a card down past the one above it", function()
    local slots = overlay.layout({ { row = 4, height = 3 }, { row = 5, height = 2 } }, 20)
    assert.same({ { start = 4, rows = 3 }, { start = 7, rows = 2 } }, slots)
  end)

  -- And the push carries on: a third card whose own anchor is free is still pushed when
  -- the second has run over it.
  it("carries a push down through every card it reaches", function()
    local slots = overlay.layout({ { row = 1, height = 4 }, { row = 2, height = 4 }, { row = 6, height = 1 } }, 20)
    assert.same({ 1, 5, 9 }, {
      slots[1].start,
      slots[2].start,
      slots[3].start,
    })
  end)

  it("leaves a card on its anchor when the one above ends before it", function()
    local slots = overlay.layout({ { row = 2, height = 2 }, { row = 10, height = 2 } }, 20)
    assert.equal(10, slots[2].start)
  end)

  it("cuts a card at the bottom of the margin", function()
    assert.same({ { start = 9, rows = 2 } }, overlay.layout({ { row = 9, height = 5 } }, 10))
  end)

  it("draws no card pushed wholly past the bottom", function()
    local slots = overlay.layout({ { row = 8, height = 3 }, { row = 9, height = 2 } }, 10)
    assert.same({ start = 8, rows = 3 }, slots[1])
    assert.is_false(slots[2])
  end)

  it("draws no card whose anchor is out of the window", function()
    local slots = overlay.layout({ { row = nil, height = 2 }, { row = 3, height = 1 } }, 10)
    assert.is_false(slots[1])
    assert.same({ start = 3, rows = 1 }, slots[2])
  end)

  -- Given last on purpose: the queue's order puts a whole-file entry wherever it was
  -- captured, and the margin puts it at the top regardless.
  it("pins a whole-file card at the top, above the anchored ones", function()
    local slots = overlay.layout({ { row = 1, height = 2 }, { pinned = true, height = 3 } }, 20)
    assert.same({ start = 1, rows = 3 }, slots[2])
    assert.same({ start = 4, rows = 2 }, slots[1])
  end)

  it("stacks several pinned cards in the order given", function()
    local slots = overlay.layout({ { pinned = true, height = 2 }, { pinned = true, height = 1 } }, 20)
    assert.same({ { start = 1, rows = 2 }, { start = 3, rows = 1 } }, slots)
  end)

  -- Two entries on one line: queue order, which `table.sort` alone would not keep.
  it("keeps the given order for cards anchored on one row", function()
    local cards = {}
    for i = 1, 12 do
      cards[i] = { row = 2, height = 1 }
    end
    local starts = vim.tbl_map(function(slot)
      return slot.start
    end, overlay.layout(cards, 40))
    assert.same({ 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 }, starts)
  end)

  it("orders anchored cards by row whatever order they were given in", function()
    local slots = overlay.layout({ { row = 10, height = 1 }, { row = 3, height = 1 } }, 20)
    assert.equal(10, slots[1].start)
    assert.equal(3, slots[2].start)
  end)
end)
