# ADR 0015: Done Marks and Working Time

Date: 2026-10-31. Status: accepted.

## Context

The sidebar, the dashboard and the menu bar showed which agents needed you and which were working. An agent that finished dropped back to idle with nothing to set it apart, so after a while away there was no telling which agents had finished. The menu bar was the worst case: an agent left its Working section on finishing and appeared nowhere.

Green was also taken twice: the dot on a row whose mirror is open, and the idle chip in the title bar.

Herdr's desktop app has a done state ("finished while you were looking elsewhere"), which becomes idle once looked at.

## Decision

**What done is.** An agent is done when it has an unread "finished" notification, is not working or waiting for you, and its turn did not stop on an error or a limit.
- The inbox already records every finished turn with a read state. Using it keeps one source, and the mark and the notification clear together.
- Notifications from before done marks existed don't count. Looking at an agent did not mark them read then: there were 32 unread "finished" items over 9 agents, some two days old.

**What seen is.** An agent is seen while it is on screen:
- It is in the main window's detail area (alone, as a tile, or zoomed), or in its own window.
- That window is not minimized, hidden or fully covered (its occlusion state).

Coming on screen marks the agent's notifications read and withdraws their banners. The same test decides whether a new notification gets a banner. Before, being selected was enough, even with the window hidden.

**Showing it:**
- Green means done, and only done, in agent status: a green check where the spinner or the orange mark of an agent that needs you goes (sidebar, tiles, palette), and a Done chip in the menu bar and the dashboard.
- The idle chip turns gray.
- An open view is no longer a green dot beside the time: it is a small gray dot on the agent's icon, as chat apps mark someone present on their picture. It takes no room of its own and is not a status color.

**Where the time and the mark go:**
- In the sidebar, as Mail sets a message's date: the time at the row's top right, the status mark at its bottom right, each against the trailing edge, so both line up down the list and a row without a mark has nothing there.
- In one-line rows (the menu bar, the dashboard), the status chip and then the time, in a fixed width that fits "23h", so times and chips line up.
- The dashboard's list of agents that need you, are done or working is titled Active, the name the sidebar's filter for the same agents has.

**Order:**
- Needs you, then done, then working, then the rest, in the sidebar, the dashboard and the menu bar.
- Grouping by status gets a Done group, and the Active filter includes done agents.
- A done agent that comes on screen keeps its place in the sidebar until it leaves, as Herdr does, so a row does not move away as it is clicked.

**The menu bar:**
- Its label shows the most urgent state with a count: needs you, then done, then working.
- Its popover has a Done section, most recently finished first, with Clear.

**Working time.**
- The app stamps when each agent's activity changes. A working agent shows for how long ("<1m", "12m", "3h"); any other shows how long ago it was last active, as before.
- The stamps come from the activity the app already resolves on each refresh, so they cost nothing remote.
- They are kept across launches for agents still doing the same thing. An agent already working when first seen, with no stamp kept, shows no time until its next change.

## Consequences

- An agent driven from another terminal gets done marks that AgentMux can't clear by itself: looking at it there is not looking at it here. Clear in the menu bar, or Mark All as Read, clears them.
- A working time is as precise as the refresh (2 s for an agent on screen, 10 s otherwise).
