# ADR 0017: Motion and Hover Feedback

Date: 2026-10-31. Status: accepted.

## Context

Several things in the app appeared, moved or changed without any motion:
- the palette and its dimmed backdrop;
- tiles joining, leaving, zooming or swapping;
- status marks, chips and spinners;
- loading states and lists.

Most buttons without a border had no hover feedback; only the sidebar footer's two had one, its own. Controls shown on hover (a tile's zoom and close, an inbox row's actions) came and went on every pass of the pointer.

## Decision

**One motion vocabulary** (`Motion`), so the same kind of change moves the same way everywhere:
- `quick`, 0.15 s ease-out: small things appearing, disappearing or changing. That covers hover feedback, controls shown on hover, status marks, chips, spinners, loading states and highlights.
- `panel`, a 0.22 s spring: something arriving over or reshaping the content, such as the palette or tiles.
- `list`, a 0.28 s snappy curve: rows moving, arriving or leaving.

**Hover feedback:**
- Buttons without a border share `HoverButtonStyle`, the sidebar footer's look: a secondary glyph that turns primary on an 8% rounded wash under the pointer. On top of that look, the wash fades in (`quick`) and deepens to 14% while pressed.
- Borderless menus (Files' +, Sessions' and the inbox's "···") get the same wash around them.
- Agent rows that are one button (menu bar, dashboard, inspector) use `RowButtonStyle`: a 6% wash under the row, as menus highlight items.
- Native list rows (sidebar, Files, Sessions, inbox) keep macOS's behavior: no hover highlight, as in Finder and Mail.
- The pointer stays an arrow on buttons; only links in previews show a pointing hand, as macOS has it.

**Controls shown on hover are debounced:**
- They appear after the pointer rests for 90 ms and go 220 ms after it leaves (`debouncedHover`).
- Feedback on the control under the pointer stays immediate.

**Tiles move without resizing live terminals every frame.** Every resize reflows the terminal and its remote tmux window, so the tile area is two layers:
- Cards (frame, header, focus ring) animate to their new places (`panel`). A lone agent has a bare card, so it can grow into a tile and back.
- Each surface takes its final size at once, hidden, and fades in 200 ms later (`quick`), when the cards have settled.
- Window resizes still resize everything live, as before.

## Consequences

- The hover styles are drawn by the app, not by AppKit. macOS has no hover wash for borderless buttons outside toolbars; NSButton's border-on-hover is a different, bezeled look. A future macOS restyle won't reach these buttons.
- The fades don't follow the "Reduce motion" accessibility setting.
- A disabled button is drawn at 40% opacity rather than in the system's disabled color.
- On borderless menus the wash is added around the native menu, so pressing one doesn't deepen it as a button does.
