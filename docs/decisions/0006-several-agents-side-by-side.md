# ADR 0006: Show Several Agents Side by Side

Date: 2026-10-28. Status: accepted. Layout picking is unit-tested (`TileLayoutTests`). The interactive parts (clicking between tiles, zoom) can't be driven in tests without typing into live agents, so they are checked by hand.

## Context

The detail area showed one agent at a time; watching two meant popping one out into its own window. The user wanted several agents on screen at once, laid out sensibly, on both a landscape main display and a portrait one.

Two constraints shape any layout:

- **Each mirror sizes its remote window.** A mirror forces its agent's tmux window to the local surface's grid (`resize-window`, ADR 0004), so a tile's size is the size the agent's TUI reflows to. Small tiles mean narrow agents, and flipping a layout back and forth reflows every one of them.
- **Agents need width more than height.** Claude Code and Codex wrap prose and draw boxes; under ~80 columns they get cramped quickly, while 25 rows is still workable. Beyond ~100 columns or ~50 rows a tile gains little.

Every agent in the monitored containers runs in its own tmux window (checked with the inventory probe), so two tiles never fight over one window's size.

## Options considered

1. **Sidebar multi-select (chosen by the user).** ⌘- or ⇧-click rows; the detail area tiles them automatically; a plain click goes back to one. No new concept: it is how a macOS list selects several items.
2. **A persistent split workspace.** "Open Beside" adds a tile that stays until closed; a sidebar click replaces the focused tile. Like an IDE's editor groups, but one more piece of state to manage.
3. **Drag-to-split with dividers.** Drop a row on an edge to split, drag dividers to resize. Most flexible and most complex, and every divider drag reflows remote agents.

## Decision

- The sidebar's `List` selects a set. One row is the usual single view. Several (up to `TileLayout.maxTiles` = 4, matching the cap on open mirrors) become `AppModel.tiles`; tiles keep their places, and new ones join at the end in sidebar order. `selection` stays the single focused agent, so everything that acts on "the selected agent" (toolbar, status bar, inspector, Files, New Terminal) acts on the focused tile. Setting `selection` to anything outside the tiles collapses back to one view.
- **Layout** (`TileLayout`, AgentMuxCore). Candidates are equal splits into columns or rows: 2 side by side or stacked; 3 as one tall tile beside two stacked, or in three columns or rows; 4 as a 2×2 grid, or four columns or rows. Each tile is scored `(min(cols, 100)/100)² × min(rows, 50)/50` with the cell size of the current font, and the candidate with the best worst tile wins (mean breaks near-ties). This gives side by side on landscape, stacked on portrait, and stacked rather than ~44-column tiles in a small window. The current arrangement is kept unless another is more than 10% better, so resizing near a threshold doesn't flip every remote window.
- **Focus and input.** Every visible tile is live and accepts its own mouse input; keys go to the first responder. A click in a tile makes its surface first responder, which reports back (`becomeFirstResponder` → `focusTile`) and moves `selection`. ⌘] / ⌘[ cycle focus between tiles (Ghostty's split shortcuts) instead of the sidebar order. The focused tile's header has an accent underline.
- **Zoom.** ⇧⌘↩ (Ghostty's split zoom) fills the area with the focused tile; the others stay mounted at their tile frames, so their remote windows are not resized.
- **One place per mirror.** Every open mirror is rendered once in a `ZStack`, framed as the full area, a tile, or hidden (opacity 0, not drawing, input closed). Moving between those never rebuilds a Ghostty surface. Frame changes are not animated, since animating a live surface would resize it, and its remote window, every frame.
- Visibility and input go through one place, `AppModel.applyVisibility()`. That also fixed a mirror popped out into its own window going dead when the main window's selection changed (an `onChange` in `RootView` deactivated every terminal but the selected one).

## Consequences

- An agent in a tile reflows to the tile's size, as it already did to the full area. A user's own client attached to that window sees it at that size while the tile is open.
- Targets of every visible tile are polled at the fast "being viewed" interval, and banners are suppressed for every visible tile.
- At most four agents tile; ⇧-clicking a longer range takes the first four and beeps.
