Translated from the original Chinese handoff document (v1.0, 2026-10-09). The original is kept locally and is not part of the repository.

## Amendments after v1.0 (2026-10-10)

The following user decisions override the corresponding text in the translated document below.

- **Terminal engine:** use the terminal engine (https://github.com/Lakr233/the terminal engine, the `the terminal engine` product) instead of a terminal component. a terminal component is no longer evaluated. (Affects sections 3.2, 8.2, 17.9, 20.)
- **Personal use only:** the app is for the user's personal use only and will not be distributed. Code from the reference projects (a Mac agent console, a reference project, a reference project, etc.) may be referenced or reused regardless of their licenses; sources should still be recorded. (Affects sections 17 and 18.)
- **No Xcode:** the project builds with a per-user swift.org Swift toolchain plus Command Line Tools; see [docs/decisions/0001-toolchain-terminal-packaging.md](decisions/0001-toolchain-terminal-packaging.md).
- **Disk budget:** disk usage on the user's Mac must stay small; any new local install needs a storage budget approved by the user first.
- **Observe-only early phase:** the early phase is observe-only on the remote server: no changes to the server, containers or tmux without the user's prior approval.
- **Language and commits:** all code, documentation and commit messages are in English; commit messages follow Conventional Commits.

---

# macOS Remote Agent Console: Product Requirements and Development Handoff

**Document version:** v1.0  
**Written and sources verified on:** 2026-10-09  
**Audience:** the development agent responsible for designing, implementing, testing and delivering this app  
**Tentative project codename:** Remote Agent Console (a working name only; it is not required to be the product name)  
**Delivery goal:** a graphical application used on the Mac that directly observes and operates tmux and coding agents inside existing Docker containers on remote servers, without depending on backend and without migrating the existing runtime environment.

> **The requirement in one sentence: I want the a Mac agent console-style Mac App experience of "all agents visible in one place, click to enter the real terminal", but the underlying stack is still my existing SSH → Docker → tmux → Codex / Claude Code. The app is a client of this environment, not a new agent runtime.**

## Reading guide and factual boundaries

This document contains three kinds of information of different nature, which must be treated differently during development.

**User facts and hard constraints** come from the workflow the user has already described and must not be quietly changed for implementation convenience. **Recommended design and acceptance targets** are the default proposals made for this development effort; they may be adjusted based on prototype results, but must not weaken the hard constraints. **Reference project facts** come from the public repositories and official documentation listed at the end; for this document, no integration testing was performed on the user's real Mac, servers or containers, and no line-by-line source audit of those projects was completed.

Dependency APIs, licenses and agent log formats may change. This document records what was visible on the verification date; that does not mean every version installed on the remote side supports it. Before development, record the actual environment versions and pin tags / commits for the dependencies you intend to use. Do not treat the hosts, containers, usernames, paths or versions in this document's examples as real configuration.

Suggested reading order: first read sections 1–5 to establish "what to build"; then read sections 7–12 to understand the main risks; implement and verify according to sections 15–16; section 17 is for researching the reference projects. Section 20 can be used directly as the initial task instruction for the development agent.

---

## 1. The user's current situation and pain points

### 1.1 Current workflow

```text
Mac
└── Royal TSX / SSH client
    └── SSH to Linux / Ubuntu host
        ├── Docker container A
        │   ├── tmux session A1
        │   │   ├── window / pane: Codex
        │   │   └── window / pane: plain shell or experiment
        │   └── tmux session A2: other agent
        └── Docker container B
            ├── tmux session B1: Codex
            └── tmux session B2: Claude Code / other tasks
```

The user starts containers, enters containers, creates tmux sessions and starts agents on their own. These tasks may already be running before the app is installed for the first time. **The application must attach to these pre-existing objects, rather than only managing sessions it created itself.**

### 1.2 Known facts

| Item | What is known | Requirement for the app |
|---|---|---|
| Local machine | Mac; has used Royal TSX to manage multiple SSH servers | Mac graphical application; reuse existing SSH connection habits |
| Remote | Mainly SSH-only Linux / Ubuntu servers | Do not depend on a remote desktop environment |
| Container entry | Can SSH into the host, then `docker exec` into existing containers; cannot SSH directly into containers | Docker must be a first-class target layer; containers must not be required to first become standalone SSH hosts |
| Session organization | Different tmux sessions / windows / panes exist in different containers | Must discover, distinguish and aggregate across containers |
| Main agents | Codex; also uses Claude Code; may extend to other CLIs in the future | Codex and Claude Code first; not tied to a single vendor |
| Multiple config directories | Has used multi-account configurations such as `~/.codex`, `~/.codex-2` | Identify config instances; must not assume by default that all Codex instances belong to the same account directory |
| Agent invocation relationships | There is a workflow where Codex makes decisions and invokes the Claude Code CLI to execute | Distinguish standalone terminal agents from child processes; do not fake a standalone interactive terminal for a child agent |
| Performance | Considers VS Code Remote heavy; has experienced container / experiment high load making `docker exec` or SSH unavailable | Remote collection must be lightweight, with timeouts, rate limiting and backoff; it must not amplify load |
| Change preference | Prefers incremental changes that do not break existing configuration and tasks | Attach-only by default; any installation, configuration write or restart requires explicit authorization |
| UI reference | Likes the Mac App UI of `a Mac agent console` | Borrow the unified sidebar, status display and terminal switching; do not inherit the backend dependency |

Do not hard-code past container names, IPs, or CPU / memory quotas into the program, and do not infer the user's actual Mac chip or OS version. Historical server specs only indicate that the setup is "resource-sensitive"; they must not be used as a reason to relax the client budget without limit.

### 1.3 Problems to solve

The user does not want to go through "switch server → enter container → find tmux → switch window / pane" every time they want to check on an agent. The ideal experience is to open one app, immediately know where each agent is and whether it needs attention, and after clicking it, continue typing in the original real terminal.

The user is not looking for a new chat frontend, a model API client, an IDE or a task keep-alive backend.

---

## 2. Product positioning and success criteria

### 2.1 Product positioning

**A tmux graphical client and status dashboard for remote, multi-container, multi-agent scenarios.**

The true state of running terminals and processes is provided by the remote tmux and operating system; the app owns only local connection configuration, display preferences, caches and observation state. A tab in the app should not automatically hold the power of life and death over remote processes.

### 2.2 Minimum success scenario

The user is already running several Codex / Claude Code instances in two containers. After opening the app for the first time, adding an existing SSH alias, and selecting these two containers and the correct users, the application should:

1. Automatically list their existing tmux sessions, windows and panes, and identify agent types that can be confirmed.
2. Show locations and evidence-backed states in a unified interface; when evidence is insufficient, show "unknown" rather than guessing "done".
3. After an agent is clicked, enter the corresponding real terminal inside the app, with keyboard input actually reaching the target pane.
4. After a view is closed, the app is quit or the network is interrupted, existing remote tasks do not end because of any action actively taken by the app; reconnecting recovers the sessions that still exist.

These four items take priority over visual animations, a file browser, automatic orchestration or model usage statistics.

### 2.3 Core evaluation metrics

| Metric | What success means |
|---|---|
| Compatibility with the original workflow | No need to relaunch agents through a dedicated launcher; Royal TSX and other tmux clients remain usable |
| Targeting accuracy | Never connects to the wrong object because of same-named sessions, `%0` in different containers, or multiple agents in the same directory |
| Interaction fidelity | Full terminal I/O, not `capture-pane` text refresh plus a fake input box |
| State credibility | Agent type, activity state and connection state are expressed separately, and the basis for each judgment can be explained |
| Task safety | Closing in the UI is clearly separated from a remote kill; old input is not resent after a disconnect |
| Resource control | No whole-disk scans, no reading full logs every second, no separate high-frequency reconnect loop per pane |

---

## 3. Hard constraints, default approach and non-goals

### 3.1 Hard constraints

| ID | Constraint |
|---|---|
| C-01 | Do not depend on backend; installing or starting backend must not be required on the Mac, the host or the containers. |
| C-02 | Keep the remote Docker + tmux way of running and keeping tasks alive; do not migrate tasks into a new multiplexer or runtime. |
| C-03 | Must support Mac → SSH host → `docker exec` container → tmux; must not require an SSH service in the container, directly exposed ports or an additional public entry point. |
| C-04 | Must discover sessions that already existed before the app started and that were created manually in other terminals. |
| C-05 | Must not require rebuilding containers, restarting Docker, stopping experiments or logging agents in again in order to attach. |
| C-06 | Multiple containers and multiple tmux servers are first-class scenarios; support must not be limited to a single tmux on the host. |
| C-07 | Provide a real interactive terminal inside the Mac app; a standalone web dashboard, or merely jumping to an external terminal, does not count as done. |
| C-08 | Do not automatically rewrite the user's shell, tmux, SSH, Codex or Claude Code configuration; any necessary change must first show its scope and diff. |
| C-09 | Do not read or take over model API credentials to replace the existing CLIs; do not change agents' permissions, proxies or login methods. |
| C-10 | Work within existing access permissions; do not automatically escalate privileges, expose the Docker API, mount the host Docker socket or bypass SSH host key verification. |

### 3.2 Recommended default approach (not to be presented as a technical choice the user has already signed off on)

The default is a native SwiftUI + AppKit shell, evaluating a terminal component first for the embedded terminal, using the system `/usr/bin/ssh`, and communicating on the remote side through the Docker CLI and tmux. the terminal engine is a comparable terminal engine candidate. The final dependencies, minimum macOS version and window structure should be decided through prototyping.

Base mode does not install any resident remote service and does not require Node.js, Python, a Rust toolchain or a browser on the remote side. Optional lightweight collectors / hooks are used only to enhance state recognition and must not become a prerequisite for "being able to see and connect to existing tmux".

Do not require the user to install Docker Desktop, Colima or a local virtual machine on the Mac. Testing should also preferably use controllable remote test containers, rather than casually deploying a whole new environment on the user's Mac.

### 3.3 Out of scope for the first version

The first version does not include: an IDE, a remote VS Code Server, a model chat API, automatic task decomposition, a multi-agent orchestration engine, an account switching tool, token / cost estimation, an iOS app, a team cloud service, Kubernetes management, automatic traversal of arbitrarily nested Docker / tmux layers, or a full file manager.

Creating new tmux sessions / agents, file and image upload, notifications, precise hooks and native multi-pane mirroring may all be added in phases; **they must not block the main line of "reliably attaching to existing sessions".**

---

## 4. Domain model: avoid conflating different kinds of "session"

| Name | Meaning in this document |
|---|---|
| Host | A configured SSH target, e.g. an SSH config alias |
| Execution target | Where commands actually run: the host itself, or a specific user context inside a specific container |
| Tmux server | A tmux service accessed through one socket; not the same thing as a session |
| Session | A tmux session, e.g. `$1`; its name is used for display only |
| Window | A tmux window, e.g. `@3`; one window may be linked into multiple sessions |
| Pane | A tmux pane, e.g. `%7`, with its own terminal and process tree |
| Agent process | A Codex, Claude Code or similar process confirmed to be running in the process tree associated with a pane |
| Agent conversation | The agent's own conversation / resume ID; it may be absent and must not be faked with a pane ID |
| Local view | A tab or terminal view in the Mac app; closing it does not mean destroying the Pane |
| Observation | One observation result carrying its source, time, evidence and confidence level |

### 4.1 Identity

It is recommended to split identity into two layers:

```text
Configured target identity = local Host UUID + Target UUID

Runtime Pane identity =
  target identity
  + full container ID (if a container) and its run generation
  + execution UID / user context inside the container
  + canonical tmux socket path
  + tmux server generation
  + pane_id
```

Sessions / Windows are independent entities organized into a tree through membership relations, rather than having the session name concatenated directly into the Pane's unique identity. Linked windows / session groups must be deduplicated: the same pane may appear under multiple tree paths but must not be treated as multiple independent agents.

The tmux documentation states that `$`, `@` and `%` IDs are unique within the corresponding server for the lifetime of the object; they must not be treated as globally permanent IDs across containers or across server restarts. [R11]

**The generation strategy is a design still to be implemented, not a UUID provided by tmux.** It may combine the tmux server PID, process start time, socket information and container start information; when continuity cannot be reliably confirmed, conservatively invalidate the old handles and rediscover. Comparing only the PID or the container name is not enough.

### 4.2 Three kinds of state must be kept separate

```text
ConnectionState: connecting | online | degraded | offline | authRequired
AgentKind: codex | claudeCode | other | none | unknown
AgentActivity: working | waitingInput | waitingApproval | idle | unknown | exited
```

In addition, track data freshness: `observedAt`, `lastVerifiedAt`, `stale`. SSH being offline does not mean the agent has exited; a plain shell is not the same as an agent whose state is unknown; an agent finishing its current reply does not mean the CLI process has exited, let alone that the whole research task has succeeded.

---

## 5. Functional requirements and priorities

**P0: must be delivered in the first version. P1: second-phase enhancement. P2: explicitly deferred.** The diagnostics and safety boundaries within a requirement are part of that requirement itself and must not be treated as optional finishing work.

### 5.1 SSH hosts and connection management

| ID | Priority | Requirement and acceptance points |
|---|---|---|
| F-01 | P0 | Manually add an SSH config alias or `user@host`; support a display name; each host can be connected and disconnected independently. |
| F-02 | P0 | Reuse the OpenSSH configuration and ssh-agent, including port, IdentityFile, ProxyJump and other capabilities handled by the system SSH. Do not hand-write an incomplete SSH protocol implementation. [R12][R13] |
| F-03 | P0 | Pre-configured key authentication works. When a password, key unlock, MFA or first-time host key confirmation is needed, show "authentication required" and provide a clear entry point for interactive authentication; do not let background tasks hang indefinitely. |
| F-04 | P0 | Show the connection stage, last successful time and readable errors; distinguish network, authentication, host key and remote command failures. |
| F-05 | P0 | Manage connection and reconnection centrally per host, with cancellation support; one unreachable host does not block the others. |
| F-06 | P1 | More complete GUI authentication, Keychain integration and a list of host candidates from SSH config. Private keys must not be uploaded. |

"Automatically enumerating every connectable host in ssh config" is not mandatory: wildcards, Include and Match cannot always be turned into a complete candidate list. In the first version, manually entering an alias is sufficient; connection semantics follow the system SSH.

### 5.2 Docker target management

| ID | Priority | Requirement and acceptance points |
|---|---|---|
| F-07 | P0 | List containers through the host's Docker CLI, showing the name, the link to the full container identity and the running state; monitor only the containers the user has selected. |
| F-08 | P0 | Per container, allow specifying the exec user, the tmux executable path and the socket selection method; record both the configured value and the actually probed UID. |
| F-09 | P0 | Allow manually entering a known container and then testing access separately; "no permission to list" and "container does not exist" must not be conflated. |
| F-10 | P0 | Update correctly when a container is stopped, paused, restarted, removed or recreated under the same name; do not keep sending input to the old Pane. |
| F-11 | P0 | Do not automatically start / restart containers. Show the conditions for recovery, but do not execute any lifecycle management command by default. |
| F-12 | P1 | Allow explicit configuration of a trusted Docker command entry point, a rootless context or an authorized non-interactive wrapper; automatic sudo / adding the user to a group as a fallback is forbidden. |

A Docker container must be an object in the application's data model, not merely an arbitrary free-text "command to run after connecting". Discovery, state collection, log access and terminal attach must all use the same target context.

### 5.3 tmux discovery and browsing

| ID | Priority | Requirement and acceptance points |
|---|---|---|
| F-13 | P0 | Automatically enumerate the existing sessions / windows / panes for the selected target, selected user and selected socket. |
| F-14 | P0 | Hierarchical view: Host → Container / Host target → Socket (when needed) → Session → Window → Pane. |
| F-15 | P0 | After an external client creates, closes, renames, switches or changes the layout, the app can refresh incrementally or perform a bounded resync. |
| F-16 | P0 | Support the default socket and explicit `-L` / `-S` configuration; must not only search a hard-coded `/tmp/tmux-0/default`. |
| F-17 | P0 | Plain shell / experiment panes remain visible and can be filtered; not being recognized as an agent does not prevent attach. |
| F-18 | P0 | Distinguish "no sessions", "user mismatch", "socket inaccessible", "tmux not present" and "command timed out"; they must not all be displayed as an empty list. |
| F-19 | P1 | Socket candidate discovery within a limited scope; by default, do not traverse all user directories or look for sessions across permission boundaries. |

### 5.4 Agent recognition and global dashboard

| ID | Priority | Requirement and acceptance points |
|---|---|---|
| F-20 | P0 | Recognize Codex and Claude Code first; support the common cases where they are launched through a shell, an alias, a wrapper or a Node entry point. |
| F-21 | P0 | Provide an aggregated agent view: type, display name, host, container, session / window / pane, working directory, activity state, data timestamp. |
| F-22 | P0 | Automatic recognition does not require the agent to have been launched by this app, nor does it require restarting the agent or pre-installing hooks. |
| F-23 | P0 | Every state shows its source / confidence level; `activity=unknown` is allowed when only the type is confirmed. |
| F-24 | P0 | Multiple Codex config directories are configurable and labeled separately; do not claim to know the real logged-in account based on directory names. |
| F-25 | P0 | When the process has exited but the terminal still shows the agent's earlier screen, it must no longer be shown as "running". |
| F-26 | P1 | When there is a reliable association, read incremental session logs to show a short task title, the conversation ID and a more precise state. |
| F-27 | P1 | Install / uninstall observation-only hooks after user authorization; must back up, preserve the existing configuration and be reversible. |
| F-28 | P1 | Show parent-child agent relationships; a child agent without its own PTY shows only association information, not a fake "standalone terminal". |
| F-29 | P2 | New providers, reliable structured usage data or browsing of past conversations. Model names, quotas or costs without supporting evidence are not displayed. |

### 5.5 Terminal interaction

| ID | Priority | Requirement and acceptance points |
|---|---|---|
| F-30 | P0 | After a Pane / Agent is clicked, attach to the existing tmux inside the app and target the correct object; do not start a new Codex process. |
| F-31 | P0 | Full TUI, Chinese input methods, Unicode, arrow keys, Ctrl key combinations, selection and copy, multi-line paste, scrolling and terminal resize all work. |
| F-32 | P0 | Text paste does not append Enter by default; programs that support bracketed paste should receive correct paste semantics; commands must not be silently submitted line by line. |
| F-33 | P0 | Can switch between multiple local terminal tabs; at minimum, support simultaneous connections to existing sessions in two different containers. |
| F-34 | P0 | Closing a tab / window and quitting the app only release the app's own connections; they do not send `exit`, Ctrl+C, kill-pane / kill-session. |
| F-35 | P0 | External tmux clients can coexist; do not use `attach -d` by default to take over other connections, and do not modify the global layout in the background. |
| F-36 | P0 | The multiple panes of an existing tmux window may initially be shown as one complete terminal; clicking an agent must target the actual pane, not just open the session and leave the user to find it. |
| F-37 | P1 | Map each remote pane to an independent native terminal view, or provide a local multi-pane mirror; do not fake it by splitting or moving remote panes. |
| F-38 | P1 | Explicit features to start a new session / window / pane / agent; follow the existing configuration by default and do not add permission-bypass flags. |

The first version may use "native sidebar + embedded full tmux terminal", rather than having to start with a reference terminal-style native per-pane mirroring. But this phasing must not be used to downgrade the final interaction to a read-only snapshot.

### 5.6 Search, notifications and diagnosability

| ID | Priority | Requirement and acceptance points |
|---|---|---|
| F-39 | P0 | `⌘K` global search across agents / hosts / containers / sessions / paths; Enter opens the corresponding terminal. |
| F-40 | P0 | Filters for "All agents", "Needs attention" and "a specific host / container"; state changes must not make the row being clicked suddenly jump away. |
| F-41 | P0 | Persist local display preferences, target configuration and the last opened view; after a restart, rediscover rather than resurrect tasks from the cache. |
| F-42 | P0 | Redacted connection diagnostics and capability probe results can be viewed; logs can be exported with size limits and do not include full terminal contents by default. |
| F-43 | P1 | Notifications for waiting for input / waiting for approval, with deduplication, cooldown and suppression while the item is currently being viewed; clicking a notification re-verifies and then jumps to it. |
| F-44 | P1 | Menu bar statistics, local task aliases / favorites, notification preferences. |

---

## 6. Interface and interaction

### 6.1 Main interface

Use "unified list + real terminal" as the main layout, not multiple chat windows or a complex IDE layout. Two sidebar modes may be offered: **grouped by agent** and **browse by infrastructure hierarchy**.

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│ Search ⌘K         All devices / Filter          Connection & data freshness │
├───────────────────┬─────────────────────────────────────────────────────────┤
│ Agents / Sessions │ lab-host > container-a > work > @3 > %7                 │
│                   │ [Codex · config-2] [Waiting for input · medium conf.]   │
│ Needs attention  2├─────────────────────────────────────────────────────────┤
│ Codex · paper     │                                                         │
│ Claude · tests    │                     Real terminal                       │
│                   │                                                         │
│ lab-host          │  Shows the remote CLI, approval UI and output as-is     │
│   container-a     │  Does not rewrap past output as chat messages           │
│     work          │                                                         │
│       @3 / %7     │                                                         │
│   container-b     ├─────────────────────────────────────────────────────────┤
│     experiments   │ Online · last verified 2 s ago · source: process/screen │
├───────────────────┴─────────────────────────────────────────────────────────┤
│ Settings       Diagnostics       Disconnect current view only               │
└─────────────────────────────────────────────────────────────────────────────┘
```

This mockup shows the information structure, not a pixel-level design. a Mac agent console's overall interaction may be used as a reference, but do not copy its branding, icon assets or unlicensed code.

### 6.2 Agent row

Each row contains at least: a type icon / text, the local task alias or terminal title, the state, and the host and container. The working directory, config instance, pane identity and evidence go in the subtitle, the details view or a hover tooltip.

Sorting puts "needs attention" first, but the area currently being operated on with focus or the mouse should stay stable. State must not be distinguished by color alone. Titles and paths are untrusted remote text; they must be displayed safely and must never be interpreted as HTML or executed as commands.

### 6.3 Wording of lifecycle buttons

Use explicit wording such as "Disconnect view", "Reconnect" and "Stop monitoring". If an "End remote pane / session" action is added in the future, it must be placed separately in a danger zone, show the full target and require confirmation.

`⌘W` closes the local view by default, and `⌘Q` quits the client by default. A user deliberately pressing Ctrl+C in the terminal, typing `exit`, or using tmux's destroy shortcuts is real terminal interaction, which has different semantics from automatic cleanup by the UI; do not claim that the application can prevent every dangerous terminal operation the user performs themselves.

### 6.4 State details

For example:

```text
Type: Codex (confirmed by process executable and argv)
Activity: possibly working (screen rule, low confidence)
Last activity: 14 seconds ago
Last connection verification: 2 seconds ago
Config label: codex-2 (user-assigned config label; does not represent a verified account identity)
```

When offline, keep the last known information and clearly mark it "stale"; disable input, and do not disguise a frozen terminal screen as online.

---
## 7. Automatic agent recognition: implementation spec

### 7.1 Two different questions

**Question A: does this pane contain Codex / Claude Code?** This mainly uses evidence such as the current command, the process tree, the executable, argv and the TTY.

**Question B: what is this agent doing right now?** This requires terminal state rules, reliably associated logs or structured events. A being true does not mean B can be determined precisely.

Base mode must work on its own; enhanced mode raises confidence, and must not make installing hooks a mandatory condition for acknowledging that an existing agent exists.

### 7.2 Layered collection

| Layer | Input | Main purpose | Default policy |
|---|---|---|---|
| L0 | tmux pane identity, current command, PID, TTY, path | Initial candidate discovery; terminal targeting | P0, enabled |
| L1 | Bounded process tree for candidate panes, executable / argv, foreground relationship | Distinguish shell wrappers, Node launchers, real agents and ordinary experiments | P0, enabled when permissions allow |
| L2 | Bounded pane screen / a small amount of tail history | Infer working / waiting state | P0, rule-based and labeled with confidence |
| L3 | Associated incremental logs within the user-configured scope | Session identity, task title, more precise state | P1, read scope explicitly authorized |
| L4 | Official agent hooks / optional collector events | More direct state and parent-child relationships | P1, explicitly installed, can be fully disabled |

Linux `/proc` provides process-related information, but access to it is permission-restricted; the implementation must not assume that every container allows reading arbitrary process details. [R20]

### 7.3 Process determination

A single collection pass should, as far as possible, cover all candidate processes of one target, rather than running `ps` multiple times for each pane. Limit traversal depth, the number of processes and execution time, to avoid per-thread scanning when experiments have many threads.

Do not rule out an agent solely because `pane_current_command == "bash"`. Likewise, do not conclude it is Codex just because the process is `node`, or that an agent exists because the terminal text contains `codex`. Check how the executable / arguments relate to the pane's process tree.

For aliases, there is no need to recover the alias name: after the alias has expanded, the real process evidence is what counts. Support configuring additional executable paths or provider rules, but this must never be designed as "the user has to manually tag every pane with an agent label".

Process identity uses the PID plus start information, not the PID alone. If the process has disappeared, permissions are insufficient, or candidate relationships conflict, the state should be downgraded; stale data must not continue to be used to make assertions.

### 7.4 Multiple config directories and log association

Each target can configure multiple Codex / Claude Code root directories. For Codex, respect `CODEX_HOME`; for Claude Code, respect its config directory mechanism; do not treat the SSH user's HOME, the container's default HOME and the agent process's actual HOME as a single value. The official Codex documentation states that its local state lives under `CODEX_HOME`. [R18]

The actual directory can be identified from user configuration, reliable clues in the process environment, or structured events. If the process environment is read, only the required directory / tmux identification fields may be used; the full environment must not be persisted or uploaded, and API keys, tokens or proxy passwords must never be saved.

The recommended priority for matching logs to panes is: an explicit binding through structured events → an explicit conversation ID plus a process relationship → multiple consistent pieces of evidence such as PID / start time / directory → conservatively leave unbound. **Do not rely only on matching working directories, and do not assign the most recently modified log to every Codex.**

Incremental log reading should record file identity and byte offset, and handle partial lines, rotation, truncation, corrupt JSON, symlinks, and the same log being referenced by multiple config directories. Re-reading entire sessions / projects directories every few seconds is strictly forbidden. Real log formats must be captured as fixtures for each actual CLI version; a schema from some third-party project must not be treated as a permanent official protocol.

### 7.5 State semantics and priority

| Activity state | Allowed determination | Disallowed shortcut |
|---|---|---|
| Working | Fresh, relevant structured work events; or reliable provider TUI signatures | Treating "the process exists" as working |
| WaitingApproval | A current approval UI or a corresponding structured approval event | Raising an alert the moment the word `approve` appears |
| WaitingInput | A current input-waiting state, or evidence that it is still waiting for the user after the turn ended | Judging the task done after a few seconds without output |
| Idle | A defined no-activity state, with no stronger busy / waiting evidence | Classifying every silent process as idle |
| Unknown | Type recognized, but the state evidence is insufficient, conflicting or stale, or the version is unsupported | Filling in green to make the UI look nice |
| Exited | Agent process exit confirmed on an online, verifiable target | Declaring exit directly because of an SSH disconnect or a container query timeout |

Fresh structured signals usually take precedence, but their scope, timing and consistency with the current process must also be considered; stale hooks must not permanently override new process evidence. Confidence should use `high / medium / low`; do not give an uncalibrated "87%".

Apply debouncing and timeouts: an input box cursor, a spinner or network jitter should not make the state flip back and forth rapidly. Do not send batches of "task complete" notifications on first discovery or on recovery after a disconnect.

### 7.6 Parent-child agents and background tasks

When Codex invokes a child process such as `claude -p`, it may be shown as "Codex, with a Claude child process". Only when the child process has its own independently accessible tmux pane / PTY may it be shown as a standalone interactive terminal.

After one turn of reply ends, background experiments may still be running. Do not translate a single Stop / turn-complete event into "all tasks completed". The official Claude Code documentation also explicitly ties Stop to the main agent finishing its response for the current turn, and provides information related to background tasks; the specific fields must be verified for each version. [R19]

### 7.7 Security requirements for the hooks enhancement layer

Hooks must be observation-only: they record events locally in the agent's environment, quickly and with a time limit. Do not let a synchronous hook wait for a network response from the Mac; the Mac being shut down must not block the agent.

Before installation, show the target config directory, the files to be modified, the diff and the backup path. When merging, preserve all other hooks; uninstalling removes only this app's own entries and can detect concurrent modifications. On an observation failure, do not return a control response that would change the approval result; do not automatically approve tool calls, and do not prevent a task from ending.

Codex and Claude Code both have official hooks documentation, which can serve as the reference for a versioned interface for the enhancement layer; event names must not be hard-coded based only on old third-party implementations. [R17][R19]

---

## 8. Recommended technical architecture

### 8.1 Layered structure

```text
macOS App
├── App / UI
│   ├── AgentDashboard, TargetTree, Search
│   ├── TerminalTabs, StatusDetails
│   └── Settings, Diagnostics, Notifications
├── Domain / State Store
│   ├── Host, ExecutionTarget, TmuxServer
│   ├── Session, Window, Pane, Membership
│   └── AgentObservation, Freshness, LocalView
├── Transport
│   ├── OpenSSHConnectionManager
│   ├── CommandExecutor (non-interactive queries)
│   └── TerminalChannel (PTY / byte stream / resize)
├── Target Adapters
│   ├── HostTargetAdapter
│   └── DockerTargetAdapter (container + exec user + socket)
├── Tmux Adapter
│   ├── Inventory / Capability Probe
│   ├── Plain Attach
│   └── Optional Control-mode Client
├── Agent Detection
│   ├── Process Evidence
│   ├── Codex / Claude Screen Rules
│   └── Optional JSONL / Hooks Sources
└── Local Persistence (configuration, display preferences, bounded cache)
```

**The most important architectural principle: DockerTargetAdapter must be shared by all remote operations.** There must never be two separate paths where "the terminal goes into the container, but state scanning / log lookup still runs on the host".

The domain model depends neither on a specific terminal engine nor on backend data structures. Detectors must not manipulate the UI directly, let alone hold permission to send user input automatically.

### 8.2 Terminal engine choice

By default, first build a minimal vertical prototype with a terminal component, because it provides a Swift / AppKit terminal component; verify Chinese input, paste, mouse and TUI behavior on the actual dependency version. [R08]

A comparison with the terminal engine is also allowed, but evaluate build complexity, Swift bridging, release packaging, the embedding API and the license. the terminal engine provides an embeddable library and examples, but whether it suits this project must be tested in practice; it cannot simply be equated with "if the the terminal engine app is installed, its terminal can be embedded". [R09]

Recommended interface: a `TerminalSurface` that receives a byte stream, emits user input bytes and reports character grid changes, decoupled from SSH / Docker / tmux orchestration. Do not write a custom ANSI / VT parser for now.

### 8.3 Two implementation paths and recommended order

| Path | Implementation | Advantages | Risks that must be accepted or resolved |
|---|---|---|---|
| A: Inventory + plain tmux attach | Structured queries feed the sidebar; on click, run a plain attach over a PTY | Validates the real chain first; lower complexity; can rely on mature terminal rendering | Shows the entire tmux window; selecting a pane / resizing may affect other clients and must be handled explicitly |
| B: tmux control-mode native mapping | The app parses the control protocol; each pane's terminal output goes into its own surface | Closer to the ideal UI; more potential for precise pane interaction and native layout | Initial screen reconstruction, the control protocol, input encoding, mouse, resize and backpressure all need careful implementation |

**It is recommended to first complete a real prototype of A and then decide the scope of B; but A must preserve correct targeting and lifecycle semantics.** Both paths share target adaptation, identity, connection management and the detection layer, to avoid having to tear everything down and rewrite later.

Control mode provides command replies and asynchronous pane / layout notifications; refer to the official protocol and to a reference project's remote tmux mirroring implementation. It is not a JSON API, and it is not enough to feed the output strings directly into a terminal. [R10][R04D]

### 8.4 Separation of the read channel, the interaction channel and permissions

The read channel handles discovery, diagnostics and detection, using an in-app allowlist; the interaction channel is driven only by explicit user input or navigation actions. Do not expose arbitrary tmux execution capability to the "background state collector" for convenience.

tmux client flags such as `read-only` must not be treated as a complete security sandbox. The application must still restrict, on its own side, which commands it can issue and to which targets.

By default, do not publish high-frequency terminal bytes packet by packet as SwiftUI state. Terminal rendering goes through a dedicated surface, and the sidebar subscribes to throttled semantic changes; use bounded queues so that data streams cannot block the main thread.

---

## 9. SSH / Docker / tmux integration details

### 9.1 System SSH and command execution

Prefer the system `/usr/bin/ssh`, launched as a local process with an argument array, explicitly managing stdin / stdout / stderr, the PTY, timeouts and cancellation. Do not use layered string concatenation such as `bash -lc "ssh ..."` as the default executor.

But be aware that even when argv is used locally, an SSH remote command still goes through remote command parsing. The remote shell, Docker arguments and the tmux command protocol are different escaping layers; do not claim "we used Process.arguments, so there is no injection risk". [R12]

All user input is first converted into a structured target, and commands are then built by a dedicated encoder. Apply type constraints and malicious-input tests to hosts, paths, container IDs, usernames, sockets and tmux IDs. Any custom command wrapper should be an explicit advanced feature, not an ordinary text setting.

Background probes must fail non-interactively; when authentication is genuinely required, switch to a dedicated flow. OpenSSH ControlMaster may be evaluated for connection reuse, but do not modify the user's ssh config, and do not use global cleanup commands that would close the user's other connections. [R13]

### 9.2 Plain queries and PTYs must not be mixed

Container discovery, tmux inventory and state queries should preferably run without a PTY, so that stdout can be parsed reliably and stderr is preserved. Streaming commands that need stdin use Docker `-i`; only the interactive terminal path uses `-t`. The user, environment and working directory for Docker `exec` should be chosen explicitly. [R14]

Do not add `-tt` to every SSH command. Terminal banners, interactive shell initialization output, CRLF and echo can all break machine protocols. When stdout is found to be polluted, diagnose it and stop parsing; do not treat a banner as container or pane data.

### 9.3 Probe order

Probe in the order Host → Docker → Container → User → tmux binary → socket → inventory; cache successful capabilities at each layer and keep the failure reasons.

Base mode may use the remote's existing shell, Docker CLI, tmux and whatever process tools are available. There is no guarantee that a container has Python, jq, GNU `ps` or a complete `getent`. When more precise collection tools are missing, degrade gracefully; do not install them by default.

When enumerating Docker, query only the required fields; do not read the full `.Config.Env`. Docker supports structured format output and inspect, which can be used for container discovery with controlled fields. [R15][R16]

### 9.4 Connection chain example (for development prototypes only)

The following assumes it has been confirmed in an isolated test environment that `lab-host` is the SSH alias, `container-a` is the test container, the execution UID is `1000`, tmux is located at `/usr/bin/tmux`, and the session name is `work`. The real product uses structured parameters and does not copy these values.

```bash
# 1. Container list on the host; no terminal allocated.
ssh -T lab-host 'docker ps --no-trunc --format "{{json .}}"'

# 2. Enumerate machine-identifier fields of panes in the given container, as the given user.
# Support for -N must be probed first; the purpose is that probing never starts a new tmux server as a side effect.
ssh -T lab-host \
  'docker exec --user 1000 container-a /usr/bin/tmux -N list-panes -a -F "#{session_id}|#{window_id}|#{pane_id}|#{pane_pid}"'

# 3. Real interactive prototype: the app's local terminal must provide a PTY for ssh and forward resize correctly.
# Do not use attach -d; -E prevents attach from updating the existing session's environment.
ssh -tt lab-host \
  'docker exec -it --user 1000 container-a /usr/bin/tmux -N attach-session -E -t =work'
```

Example 2 returns only controlled ID / numeric fields. **The production protocol must not casually join arbitrary session names, titles or paths with `|`, tabs or newlines and then split them.** Untrusted text needs explicit encoding / escaping plus parsing tests; when a JSON emitter is available, use a real JSON encoder rather than building pseudo-JSON by string concatenation.

Example 3 only demonstrates the transport chain; it does not implement all of the logic for "click any pane and target it precisely". That logic must use real IDs inside the adapter and avoid accidentally changing other clients' focus.

### 9.5 Prototype notes for tmux control mode

For a machine pipe without a TTY, `ssh -T` → `docker exec -i` → `tmux -C` can be evaluated; if the terminal-integration style `-CC` is used, its terminal mode and surrounding control sequences must be handled. `-C` and `-CC` must not be treated as interchangeable string prefixes. [R10]

The control connection must correctly correlate `%begin` / `%end` / `%error` replies, and handle asynchronous notifications and escaped output bytes. Handle fragmented reads, oversized frames, unknown notifications, stderr, disconnects in the middle of a frame, and version differences. **Decode the bytes first, then hand them to the terminal engine; do not arbitrarily split the stream as UTF-8 text first and then try to reassemble it.**

Protocol parsing uses a stateful parser; do not cobble something together from a few regexes over the whole stream. The command queue has an upper bound, timeouts and cancellation; blindly replaying unacknowledged operations after a disconnect is forbidden.

### 9.6 Snapshots, the output stream and the initial screen

A plain PTY attach can rely on tmux to redraw the real terminal. Native control-mode pane mirroring, however, must design how the initial screen, cursor, size, alternate screen, history and live output are synchronized.

What `capture-pane` returns is a screen / history snapshot, not the complete internal terminal state, and it carries no built-in guarantee of seamless ordering relative to future output. If snapshot plus live stream is used, duplicates, losses and races must be handled, and it must be demonstrated that TUIs such as Codex / Claude Code / vim display correctly. Each round of snapshots must not be appended to the terminal, which would cause endlessly repeated scrollback.

Background panes are not fully streamed by default. Based on capabilities, choose to receive metadata only, subscribe on demand, capture in bounded amounts, or poll; the relevant control-mode client flags must be verified for each version. [R11]

### 9.7 Potential impact of tmux on the existing environment

Even a plain attach may increase the client count, trigger user-configured hooks or take part in size calculation. Do not promise that attach has "absolutely zero side effects" under every custom configuration the user may have.

It is recommended to attach to existing sessions with options that do not update the environment, and to keep the monitoring connection from becoming the client that determines the window size. Do not quietly `set-option -g`, rewrite the status bar, modify prefix / mouse / update-environment, or zoom / break / join panes to get a full-screen view. tmux provides related mechanisms such as `-E` and `ignore-size`, but what applies depends on support in the actual version. [R11]

If the remote has a configuration that destroys the session / server when the last client disconnects, or has dangerous detach hooks, a warning must be shown; do not change it silently. **The app's task keep-alive guarantee rests on the premise that tmux itself normally keeps sessions alive on detach.**

### 9.8 Target focus and input safety

Clicking in the sidebar only selects an object; before keyboard input is sent, confirm that the actual interaction target has been switched successfully. When the input target is unconfirmed, the server generation has changed or synchronization has failed, disable input; do not "guess a current pane".

In some tmux versions / modes of operation, pane focus and window size are shared state; the prototype must be tested with an external client connected at the same time. If per-client independent focus cannot be achieved, clearly show the side effects or adopt a more suitable pane-targeted interaction approach, rather than falsely claiming that the clients do not affect each other.

If the target is found to have options enabled that spread input, such as `synchronize-panes`, by default hold off on enabling app input and explain the risk, continuing only after explicit user confirmation; do not silently disable the user's setting, and do not display "input goes to this pane only" while knowing that input will be broadcast. For configurations in which the last client disconnecting destroys the tasks, a risk confirmation or a safe refusal must be given before the first attach, rather than informing the user only at exit time.

---

## 10. Disconnect, exit and recovery semantics

### 10.1 Events and behavior

| Event | What the app must do | What the app must not do |
|---|---|---|
| Close a local tab | Precisely release the connection / client belonging to that view | Send `exit`, Ctrl+C or kill-pane |
| Quit the app | Stop collection, disconnect the connections it holds, save local preferences | End remote tmux / agents, or close an SSH master shared with the user |
| Mac sleep / network drop | Freeze the screen, mark it stale, disable input, pause / back off | Judge the session done, or accumulate large numbers of exec retries |
| Network restored | First verify target identity, then rebuild the inventory and the available terminals | Automatically resend the user's last input or start another agent with the same name |
| Container restart | Mark the old run generation invalid and rediscover | Claim that the original tmux / agent processes are still there |
| Agent exits | Update the activity state after online verification; a plain shell may remain | Automatically resume / restart, unless there is a separate explicit feature with authorization |
| tmux server restart | Invalidate old Pane handles and log associations | Bind a new pane to an old conversation just because `%0` is the same |

The Docker documentation explains that commands started through exec depend on the container's main process running, and that a container restart does not automatically restart the original exec command. Connection recovery and process recovery must be treated as different concepts. [R14]

### 10.2 Reconnection design

Per Host, apply a unified exponential backoff with random jitter, a concurrency cap and an entry point for the user to cancel; after a threshold of consecutive failures is reached, trip a circuit breaker or reduce the frequency. Container unavailability and host unavailability are handled at separate layers.

Once terminal input has been sent and a disconnect then occurs, it is often impossible to know whether the remote side received all of the bytes; the state should be "send result uncertain", **and the input must never be resent automatically**. The user's unsubmitted local draft may be kept, but must be clearly marked as not sent.

When the application exits, it should preferably detach precisely the tmux clients it holds, or close the corresponding local channels. Do not use global cleanup such as `detach-client -a`, `kill-server` or a fuzzy `pkill`.

### 10.3 No guarantees that cannot be kept

The app does not guarantee that remote SSH is always available, and it does not replace resource isolation, OOM protection, disk capacity management or experiment checkpoints. When background services, the host, containers or tmux are terminated externally, the app can only report this truthfully; it cannot resurrect the original processes.

---

## 11. Performance and resource budget

The numbers in this section are **starting targets for development acceptance; they are neither measured performance nor hardware specifications set by the user**. Use Release builds, record the test hardware, load and network conditions, and then adjust to a reasonable budget.

### 11.1 Reference load

First-round stress scenario: 2 SSH hosts, 4 containers in total, 8 tmux sessions, 40 panes, of which 20 are recognizable agents, with 2 terminals being displayed. Most of the panes not being viewed are quiet; additionally set up a high-output pane for testing.

| Item | Suggested starting target |
|---|---|
| Steady-state sidebar / metadata CPU | Mac average below 5% of a single logical core, excluding high-throughput foreground rendering |
| Mac memory | In the reference scenario above, process RSS should stay within 300 MiB where possible; record the impact of the terminal engine and history buffers |
| Remote collection CPU | Total additional collection added by the app per host: stable average below 1% of a single core |
| Remote additional memory | Collection-related resident processes combined target below 64 MiB, excluding the existing tmux / agents / Docker daemon |
| Metadata network | In quiet scenarios, average below 30 KiB/s per host, excluding the traffic of the terminal the user is viewing |
| Sidebar updates | When online and not overloaded, ordinary additions / removals are visible within 5 seconds; the degraded polling path may take up to 10 seconds and shows the refresh time |
| Switching to an already-connected terminal | Local operation feedback target below 200 ms; remote recovery is measured separately and must not be presented as instantaneous local completion |
| Soak test | At least 8 continuous hours, with no continuously growing connections, child processes, queues or caches |

### 11.2 Scheduling defaults

Suggested defaults: refresh the container list every 30–60 seconds, with manual refresh supported; pane inventory uses event-driven updates plus periodic reconciliation, or one batched query every 3–5 seconds; stable agent process information updates every 5–10 seconds, and the state of foreground candidates may update somewhat faster. Reduce the frequency when the app is unfocused, offline or overloaded.

Batch per Host / Container; do not build an independent `ssh → docker exec → ps → capture` loop for each pane. Guarantee that the next collection round cannot pile up without bound before the current round has finished.

Over the long term, collect only from the selected containers. Do not monitor all containers, all users or all directories "in case they might be needed later".

### 11.3 Limits and backpressure

Every command has a timeout, stdout / stderr size limits, a concurrency limit and cancellation. By default, screen detection reads only a limited number of lines / bytes; long history is loaded on user action. Incremental log reading has a per-round budget; when the budget is reached, show a catching-up state.

Terminating the local SSH process does not mean that the remote command has exited in every case. Scans that are prone to hanging for long periods are forbidden; where necessary, use a remote time-limit mechanism that has been probed as available, and after termination verify that no collection processes have been left behind.

For control-mode terminal streams, do not arbitrarily drop intermediate bytes while continuing to render. When the queue budget is exceeded, an explicit pause, resync or disconnect strategy is required. Insufficient performance should lower the observation precision, not slow down the agent.

---

## 12. Security, privacy and configuration writes

### 12.1 Transport and access

Use only the user's existing SSH trust chain. Do not set `StrictHostKeyChecking=no` to hide connection problems, do not enable agent forwarding by default, and do not open public management ports on the host or the containers.

The SSH configuration itself may contain local behavior such as ProxyCommand and should be treated as configuration trusted by the user; warn about the risks when configuration is imported from external sources. No probe result, container name, pane title or terminal output is ever an executable instruction.

### 12.2 Data minimization

By default, save only connection settings, target selections, local aliases and a limited state cache. Terminal output, chat contents and prompts are not persisted; by default, diagnostic logs contain no keystroke contents, full argv, environment, tokens or private keys.

Enhanced log reading requires a scope authorized by the user. File paths, working directories and prompts may also be sensitive; provide cache clearing and an export preview. Unless the user enables it, do not send telemetry, remote output or state to third-party services; state classification does not call paid LLM APIs.

### 12.3 Terminal security

Remote output may contain OSC sequences, hyperlinks, clipboard writes, images or other control sequences. Use a trusted terminal engine and define an explicit clipboard / file / external link policy: never run a local shell, write local files or send the clipboard out merely because a control sequence was received.

Paths, task titles and links in the UI must be escaped. Notifications hide sensitive body text by default and show only the agent label and location; full content is an optional setting.

### 12.4 Local credentials and process management

Prefer leaving credential management to the system SSH and ssh-agent. If a password genuinely has to be stored, use the Keychain; never write it to JSON, UserDefaults, logs or command lines. Manage the app's own child processes and control sockets, restrict file permissions, and avoid shared temporary paths that could be replaced by other users.

### 12.5 Change protocol for optional remote writes

Before installing a hook / helper, creating a new session or modifying configuration, the following must be made explicit: the target, the action, the reason, the write path, the diff and the rollback method. The user must be able to decline the enhanced installation and continue in base mode. Configuration merging uses a parseable, structured strategy to avoid overwriting the user's hand-written content; where necessary, compare the hash of the original file to detect concurrent changes.

Uninstalling the local app should not require restoring the remote runtime environment. If the enhancement layer was enabled, provide a separate uninstall step that cleans up only files / entries confirmed to have been created by this app; it must never recursively delete the entire `.codex`, `.claude` or tmux socket directory.

---
## 13. Configuration model and internal interface suggestions

### 13.1 Local configuration sketch

The following is a proposed configuration structure, **not a format that any existing product can import directly**. The example names, UIDs and paths are for illustration only and must not be hard-coded into the actual program. Sensitive credentials do not go into this file.

```json
{
  "schemaVersion": 1,
  "hosts": [
    {
      "id": "host-lab",
      "displayName": "Lab server",
      "sshDestination": "lab-host",
      "enabled": true
    }
  ],
  "targets": [
    {
      "id": "target-a",
      "hostId": "host-lab",
      "kind": "docker",
      "containerSelector": {
        "name": "container-a",
        "replacementPolicy": "requireConfirmation"
      },
      "execUser": "1000",
      "tmuxExecutable": "/usr/bin/tmux",
      "tmuxSocket": { "mode": "default" },
      "monitorEnabled": true,
      "agentProfiles": [
        {
          "label": "codex-main",
          "provider": "codex",
          "configRoot": "/home/worker/.codex"
        },
        {
          "label": "codex-2",
          "provider": "codex",
          "configRoot": "/home/worker/.codex-2"
        }
      ],
      "enhancedLogCollection": false,
      "hooksIntegration": false
    },
    {
      "id": "target-b",
      "hostId": "host-lab",
      "kind": "docker",
      "containerSelector": {
        "name": "container-b",
        "replacementPolicy": "requireConfirmation"
      },
      "execUser": "1000",
      "tmuxExecutable": "/usr/bin/tmux",
      "tmuxSocket": {
        "mode": "path",
        "value": "/tmp/example-tmux/agents.sock"
      },
      "monitorEnabled": true,
      "agentProfiles": [],
      "enhancedLogCollection": false,
      "hooksIntegration": false
    }
  ],
  "preferences": {
    "defaultSidebar": "agents",
    "closeViewAction": "detachOnly",
    "autoReconnect": true,
    "persistTerminalContents": false,
    "telemetryEnabled": false
  }
}
```

Full container IDs, run generations and discovered panes are stored in a separate runtime cache and never write back over the user configuration. A container rename may keep the identity; recreation under the same name should be handled as an identity change, with the association re-confirmed; the old input queue and old log mappings must not be carried over.

### 13.2 Suggested module boundaries

| Module / interface | Responsibilities | Must not be responsible for |
|---|---|---|
| `HostConnectionManager` | Authentication, connection reuse, availability, backoff, cancellation | Agent state classification, launching tasks |
| `ExecutionTargetAdapter` | Run controlled commands in the correct host / container / user context | Arbitrary string concatenation and UI logic |
| `TmuxInventoryService` | Capability probing, object discovery, incremental updates, generation verification | "Fixing" an empty list by creating a new session |
| `TerminalAttachmentService` | Connecting to existing terminals, byte I/O, resize, precise detach | Automatic resume, automatic approval |
| `AgentDetector` | Turning evidence into type, activity state and confidence | Calling cloud models by default to guess state, sending keystrokes |
| `ObservationStore` | Merging snapshots / events, handling expiry and reconnect generations | Treating the cache as the true remote state |
| `LocalSettingsStore` | Config migration, aliases, preferences, bounded cache | Storing agent tokens or full logs |
| `DiagnosticsService` | Redacted logs, metrics, error reports | Recording the screen / logging all terminal output by default |

Internal data messages should include schemaVersion, targetIdentity, generation, event / request ID, observedAt, source and freshness; these are internal contracts within the app and do not imply deploying a remote RPC service.

### 13.3 Error classification

At minimum, distinguish: `SSH_AUTH_REQUIRED`, `SSH_HOST_KEY_MISMATCH`, `HOST_UNREACHABLE`, `DOCKER_PERMISSION_DENIED`, `CONTAINER_NOT_RUNNING`, `CONTAINER_REPLACED`, `EXEC_USER_INVALID`, `TMUX_NOT_FOUND`, `TMUX_SOCKET_UNAVAILABLE`, `NO_TMUX_SESSIONS`, `TARGET_GENERATION_CHANGED`, `UNSUPPORTED_CAPABILITY`, `COMMAND_TIMEOUT`, `OUTPUT_LIMIT_EXCEEDED`, `PROTOCOL_DESYNC`, `AGENT_STATE_UNKNOWN`.

`NO_TMUX_SESSIONS` is a legitimate empty state; `AGENT_STATE_UNKNOWN` means insufficient observation capability, not that the terminal is unusable. Error reports should state the layer where the error occurred, give an actionable explanation and include a redacted diagnostic identifier.

### 13.4 Capability negotiation and version compatibility

Record, per target, the versions of Docker / tmux / the available process tools and the required capabilities. Version numbers can help with the assessment, but before actually using a command / format, verify that it is available.

Do not force the user to upgrade tmux for the sake of the app; when a feature is unsupported, use a safe degradation path or disable it explicitly. The minimum officially supported version is decided by the prototype results; do not copy the version restrictions a reference project applies to its own mirroring feature.

The minimum macOS version and Intel / Apple Silicon support are likewise determined by the user's actual devices and the chosen dependencies. macOS 14+ may be used as an initial engineering assumption, but it must be verified before building, rather than guessing the system from a browser UA.

---

## 14. Boundaries of second-phase enhancements

### 14.1 Creating new agents

Creating new agents is a separate feature and must not become a prerequisite for attaching to existing agents. The target container, user, working directory, command / config instance and tmux object must all be explicit. Follow the user's proxy, authentication and CLI permission policies; do not automatically add `--dangerously-*` or similar bypass flags.

Do not wrap every agent in the app's own orchestration process for the sake of state recognition. When a shell alias / login environment is needed, document the launch method separately; do not make discovery depend on interactive shell initialization.

### 14.2 File / image upload

The user's main need is not file management, so this is deferred from the first version. In the future, data can be written over an SSH stream into a controlled, user-writable directory inside the target container, and the in-container path then pasted into the terminal.

It must be verified that the path is actually inside the container where the agent runs. Do not just transfer the file to the host and insert a host path into the container's terminal. The implementation needs a size limit, progress, conflict handling, cancellation and cache cleanup, and must not require deploying SSH into containers for this purpose.

### 14.3 Notifications

Notifications must be based on state transitions, not on individual polls. Message bodies are kept minimal; when an old notification is clicked, verify that the object still exists. The app's own connection-failure notifications and agent waiting-for-input notifications use different categories.

### 14.4 Automation interface

In the future, a restricted local command / socket API may be provided to make it easier to integrate the user's existing Codex → Claude workflow. But this is not a goal of the first version, and it must not, by default, open an unauthenticated remote control port or automatically broadcast input to multiple agents.

---

## 15. Development milestones and execution order

Milestones advance on acceptance results; no time commitments are assumed. Each phase delivers buildable code, test results, remaining limitations and the corresponding documentation. Do not build a lot of UI before the remote chain works end to end.

### M0: Environment, dependencies and minimum chain validation

Confirm the user's Mac OS version / architecture, the available Xcode toolchain, as well as the test SSH alias, the test container user, the tmux path and the socket. When real connection parameters have not been provided, start with fixtures and an isolated test environment; do not guess host credentials from old conversations.

Check the licenses of candidate dependencies, pin commits / tags, and record them in `docs/references.md`. Write short architecture decision records for the terminal engine and for plain attach versus control mode.

**Exit criteria:** a minimal Mac window can connect, through a real SSH → Docker → tmux chain, to a pre-existing test session; Chinese input and multi-line paste can be tested; after the window is closed, the PID of the remote test process is unchanged. Without a real environment, label it truthfully as "passed in simulation, real chain not accepted"; completion of M0 must not be claimed.

### M1: Multiple targets and the existing session inventory

Implement the shared TargetAdapter, SSH connection management, container selection, tmux inventory, a correct identity model, error classification and a native tree sidebar. After the user adds / renames sessions in an external terminal, the app can refresh.

**Exit criteria:** same-named sessions and duplicate `%0` panes in at least two containers are not confused; the correct user / a custom socket can be discovered; permission errors are not shown as an empty list.

### M2: Reliable real terminal

Implement click-to-target, multiple local tabs, terminal byte streams, resize, IME, copy and paste, disconnect and detach. Test while Royal TSX / another standard tmux client is connected at the same time.

**Exit criteria:** input goes correctly to the target pane, and switching never sends it to the old pane; other clients are not displaced; close, crash and reconnect tests do not actively end remote tasks; input is not replayed.

### M3: Basic agent recognition and global dashboard

Implement Codex / Claude Code process recognition, screen rules, state confidence, the unknown state, plain shell filtering, multiple config labels, global search and diagnostics.

**Exit criteria:** real processes can be discovered without installing hooks or restarting existing agents; the test fixtures are classified correctly; misleading history text, multiple processes in the same directory and silent computation do not trigger a false "done".

### M4: Stability, performance and a usable release

Complete rate limiting, output budgets, thread / process leak checks, the 8-hour soak, disconnect recovery, target recreation, config migration and security testing. Deliver a `.app` that can be opened on the user's Mac, together with build instructions. Signing / notarization may be arranged according to the distribution method, but packaging problems must not be masked by disabling system security mechanisms.

**Exit criteria:** all acceptance items in section 16 that apply to P0 pass; unimplemented P1 items are explicitly recorded; there are no absolute-path dependencies that only work on the developer's machine.

### M5: Optional enhancements

Based on real usage, implement hooks / incremental logs, notifications, native pane mirroring, new task creation and file upload. Each enhancement can be disabled independently and rolled back independently. Re-evaluate CPU / memory / installation permissions before introducing a remote helper; it must not force all users to migrate.

---

## 16. Acceptance matrix and testing requirements

### 16.1 Functional and boundary acceptance

| ID | Scenario / action | Expected result | Level |
|---|---|---|---|
| T-01 | Before the app is installed, manually create tmux in two containers and run agents | Discovered on first connection; no restart through the app required | P0 |
| T-02 | Containers A and B both have a `work` session and a `%0` pane | Lists and input are fully distinguished; no command crosses targets | P0 |
| T-03 | Two UIDs in the same container, each with its own tmux; only one is authorized | Only configured, accessible objects are discovered; error reasons are clear | P0 |
| T-04 | Default socket, `-L` socket, `-S` custom path | Access can be configured correctly; when misconfigured, no new server is created | P0 |
| T-05 | An external client creates, renames, closes or links windows | The list stays in sync; a linked pane is not counted as multiple agents | P0 |
| T-06 | Session names / paths containing spaces, quotes, Chinese characters or delimiters | The protocol does not break; nothing turns into an extra command | P0 |
| T-07 | Malicious input in host / path etc. containing a leading `-`, `;`, newline or `$()` | Safely rejected or correctly encoded; no command injection | P0 |
| T-08 | The tmux foreground shows `bash` / `node`, while an agent is actually running underneath | Recognized by combining process evidence; not judged only by the short foreground name | P0 |
| T-09 | `codex` appears in the shell history, but the process has exited | Not misjudged as still having an active agent | P0 |
| T-10 | `vim codex_notes.md` or `grep claude log.txt` | Not classified as a real Codex / Claude Code | P0 |
| T-11 | Two Codex instances in the same cwd, simultaneously using different CODEX_HOME values | Configuration, task title, conversation or state are not bound to the wrong instance | P0; log part P1 |
| T-12 | The agent produces no output during a long tool call | Does not declare done / waiting for input based on silence alone | P0 |
| T-13 | Real input-waiting and approval screens | Correctly distinguished when rules support it; marked unknown when rules do not match | P0 |
| T-14 | SSH drops, the host hangs, Docker exec times out | Marked offline / degraded, the UI remains operable; the task is not judged to have exited | P0 |
| T-15 | Click to switch quickly among multiple agents and type | Only the confirmed current target receives input; input typed during a switch is not misdirected | P0 |
| T-16 | Paste Chinese text, emoji, 200 lines of text and code | Not auto-submitted line by line; no lost characters, no extra Enter appended | P0 |
| T-17 | IME composition, the candidate window, Shift / Option / Ctrl shortcuts | Compatible with what terminal applications expect; the candidate window does not jump around | P0 |
| T-18 | Multiple clients attached at the same time, synchronized resize | Does not displace others; display is accurate; side effects of the shared size are handled / disclosed | P0 |
| T-19 | Close a tab, close a window, ⌘Q, force-quit the local app | No remote kill / exit is issued by the app; the original test tasks keep running | P0 |
| T-20 | Mac sleep and wake, Wi-Fi interruption, network switch | Rediscovers and re-attaches; old input is not resent; no duplicate task | P0 |
| T-21 | Container restarted / removed and recreated under the same name | Old handles are invalidated, the new target is re-verified, and it does not impersonate the old processes | P0 |
| T-22 | The tmux server restarts and reuses `%0` | Old input is not sent to the new pane automatically; the old conversation label is not inherited | P0 |
| T-23 | Codex starts a non-interactive Claude child process | No fake standalone interactive terminal; the association may be shown in degraded form | P0 boundary; tree display P1 |
| T-24 | Compare proxy, account directory and tmux hooks configuration before and after | Base mode writes no configuration; attach does not update the environment on its own initiative | P0 |
| T-25 | Synchronized input enabled / dangerous user-defined tmux configuration | Clearly warns about the impact of the existing configuration; does not turn off user settings on its own initiative | P0 |
| T-26 | Remote output contains OSC clipboard sequences, hyperlinks, malicious titles | Handled according to the security policy; no local commands executed, no silent data exfiltration | P0 |
| T-27 | 40-pane reference load sustained for 8 hours | Connections / processes / caches stay bounded; a CPU / RSS / network report is provided | P0 |
| T-28 | A high-throughput terminal combined with a slow network | Backpressure or resync stays under control; no unbounded memory growth, the UI is not frozen | P0 |
| T-29 | A minimal container lacking Python / jq / GNU ps | The basic session inventory and attach work; detection degrades in an explainable way | P0 |
| T-30 | State logs with partial lines, rotation, truncation, duplicates, symlinks | Incremental reading without crashes, without full rescans, without mis-binding | P1 |
| T-31 | After hooks are installed: the Mac is shut down, the helper is unavailable | The agent is not blocked by collection failures; permission decisions are not changed | P1 |
| T-32 | The user modifies the same configuration while hooks are being uninstalled | The conflict is detected; only the app's own entries are removed; other parties' configuration is not overwritten | P1 |
| T-33 | Reconnection restores an old WaitingInput state | Old "done" notifications are not resent in bulk | P1 |

### 16.2 Automated test layers

**Unit tests:** target identity, command encoding, message framing, tmux output parsing, state merging / expiry, provider rules, config migration, log redaction. Random byte fragmentation, invalid UTF-8, oversized input and out-of-order events must be covered.

**Integration tests:** use isolated tmux sockets and controllable test containers to test against real OpenSSH / Docker / tmux. Test resources carry a clear marker, and cleanup touches only the objects created in that run; global prune, kill or restart must never be run against production environments.

**End-to-end tests:** in the real macOS terminal engine, verify Chinese input, multi-line paste, focus, zoom / resize, mouse, network loss and recovery. Necessary manual steps are recorded as a checklist; text snapshot tests cannot substitute for input method acceptance.

### 16.3 Test criteria for state detection

Maintain labeled screen / process / event fixtures, including at least working, waitingInput, waitingApproval, unknown, exited, and plain shells that are easy to misjudge. Record the provider versions each rule supports.

Reports must give the following separately: type recognition accuracy, activity state accuracy, unknown coverage, and the number of false "done" / false approval notifications. **Do not claim zero errors by outputting unknown for every sample; and do not report only an overall accuracy that masks false positives.**

For the standard fixtures included in the first version's support scope, all expected states must pass; unsupported real versions may degrade conservatively and provide diagnostics. Real CLI integration tests require the user's existing login and do not add new model API credentials; tests that consume quota must be labeled, and agents must not be run in large volumes covertly.

### 16.4 P0 definition of done

All hard constraints are satisfied; the P0 requirements and their corresponding tests have actual results; the runnable app, source code, build instructions, test report, dependency license inventory and known issues are all present. Screenshots alone, mock data alone, or a single command that can be run in an external terminal do not count as delivery.

---
## 17. Reference projects: what specifically to reference and what not to copy

All of the following projects are technical references, **not finished products verified to directly satisfy the full SSH → Docker → existing tmux chain**. Read first the parts the user actually needs; do not bring in a project's runtime, relay, web service or agent launch model just because the project has many features.

### 17.1 Overview

| Project | Parts to reference first | Relationship to this project | License / reuse notes |
|---|---|---|---|
| `a Mac agent console` | Mac unified sidebar, search, state, real terminal interaction, separation of UI and data layer | The primary product experience reference; the backend backend is not adopted | a noncommercial license; do not copy it over as if it were MIT code. [R01][R01L] |
| `org/a reference project` | tmux-first Mac app, embedded terminal, session / window / pane tree | Conceptually very close; reference its object relationships and terminal navigation | The README currently lists the License as TBD; by default reference the design only, and resolve licensing before reusing any code. [R02] |
| `org/a reference project` | Layered agent detection, incremental logs, rules and state merging | Key reference for the recognition engine; not a mandatory runtime dependency | MIT; notices must still be kept and specific dependencies checked. [R03][R03L] |
| `org/a reference project` | Remote tmux Mirroring, control protocol and native pane rendering | Important reference for the control-mode approach | Project code is GPL-3.0-or-later by default; a designated server directory uses BUSL-1.1 instead; do not reuse it on the assumption that it is MIT. [R04L] |
| `org/a reference project` | Discovery of existing tmux, agent log matching, state aggregation | Reference its data and detection flow, not its web product form | MIT; its remote service model is not used as the base architecture. [R05][R05L] |
| `org/a reference project` | tmux session preservation, desktop state and notification interaction | Supplementary product reference | The website states MIT; re-check specific components before distribution; do not introduce the relay as a required dependency. [R06][R06D] |
| a reference terminal tmux Integration | Control mode, relationship between remote windows / panes and local windows | Comparison point for interaction and lifecycle semantics | This document cites only the public documentation; copying source code without review is not recommended. [R07] |
| `org/a terminal component` | Swift / AppKit embeddable terminal and examples | Terminal component to evaluate first by default | MIT; pin the actual API version. [R08][R08L] |
| `org/the terminal engine` | the terminal engine, terminal embedding examples and rendering | Alternative terminal engine candidate | The repository states MIT; verify dependency / bridging components separately. [R09] |

### 17.2 a Mac agent console: mainly learn from the interaction, do not inherit the backend model

The project puts multi-device agents, terminals, search and state into a native Mac interface; its architecture explicitly separates `Packages/UIKit` and `Sources/App` into layers, and the backend works through backend RPC / attach. [R01]

This project should learn from the experience of "click an agent to enter the real terminal", "location is clear" and "state is right in the sidebar", rather than simply replacing `agent attach` with a single tmux command. The underlying objects, discovery method, lifecycle and event protocol are all different.

**Source reading entry points:** the Architecture section of the README, `Packages/UIKit`, `Sources/App`. First confirm the current terminal engine and migration status, then borrow its way of decoupling the UI from transport. Where code, assets or derivative versions are involved, handle them according to its license first; whether the user will release commercially in the future has not been decided, so by default do not fork it directly as the base of this project. [R01L]

### 17.3 a reference project: the closest tmux-first product model

The project combines a SwiftUI sidebar, an embedded the terminal engine terminal and a tmux session tree, and provides SSH targets. Its current README explicitly states that the local agent metadata path is opt-in during the performance rewrite, and the tmux inventory fast path is used by default. [R02]

Its design of "separating session existence from enhanced state" is worth learning from. Do not inherit its optional automatic session creation behavior as this product's default, and do not assume it already handles anything like a DockerTargetAdapter.

**Reading entry points:** `README.md`, `docs/product/`, `docs/decisions/`, `Sources/`, `Tests/`. The `License: TBD` in its README is an explicit obstacle to reuse; being visible on GitHub does not by default grant permission to copy code. [R02]

### 17.4 a reference project: key reference for the recognition and state engine

It combines process / tmux screen heuristics with Claude hooks and Codex / Claude JSONL signals, distinguishes deterministic results from heuristic ones, and uses offset tracking for Codex logs. [R03]

This project can borrow its split into evidence, provider, resolver and source health, and study `crates/`, `providers/` and `fixtures/`. But its daemon is not a prerequisite for the first version; first implement the limited rules and data contracts that are needed, and evaluate later whether to reuse any part of it.

MIT does not remove implementation risk: state inference, log association, multiple CODEX_HOME values, container users and sockets still need to be verified with the tests in this requirements document. [R03L]

### 17.5 a reference project: reference for control mode and native mirroring

Its Remote tmux Mirroring documentation describes the SSH + tmux control connection, session / window / pane mapping, command reply correlation and pane output rendering, and can be used to study this project's path B. [R04D]

The publicly available mirroring entry point targets SSH hosts and must not be regarded as Docker support as-is. The documentation also lists limitations around mirror recovery, history reflow and multi-line paste; these limitations should be turned into tests for this project rather than inherited without judgment. [R04D]

**Code search entry points:** in a pinned version, search for `remote.tmux`, `ssh-tmux`, `%begin` and `%output`, then locate the implementation and tests. Do not guess that some old file path still exists. Verify the license against both the root-level and file-level notices; by default, implement the protocol adapter independently, and do not merge GPL code without attribution into a project under a different license. [R04L]

### 17.6 a reference project: discovery of existing tmux and log matching

a reference project is a tmux web GUI for agent TUIs; it can discover local / SSH-remote tmux and infers state by combining terminal content with logs. [R05]

Focus on the discovery, state classification, session matching and reconnection logic in `src/` and `tests/`. Its WebSocket / web service architecture is not the delivery form the user asked for; "can access a remote over SSH" also does not mean "will read the correct logs in the container user's context".

Its MIT-licensed code may be evaluated for reuse under that license, but this project does not therefore require Node / Bun on the remote or a public web service. [R05L]

### 17.7 a reference project: notifications can be borrowed, the relay route is not adopted

a reference project provides desktop / remote management around tmux; its Remote documentation describes a daemon and a relay, and states explicitly that the relay can read terminal and transmitted content. [R06D]

Its interaction for pending states, notifications and returning to the original session can be used as a reference. Do not use its connection model directly as the foundation of this product, because the user's requirement is the existing SSH + Docker chain, not new pairing, relays or cloud accounts.

### 17.8 a reference terminal: comparison for lifecycle and terminal mapping

The a reference terminal documentation is useful material for understanding native window mapping of tmux and control-mode interaction. Note in particular: some of its "close mapped tab / pane" behaviors act on the remote objects, whereas this app's default close must be detach-only. [R07]

Use a reference terminal as a manual comparison tool; do not install it as a required dependency of this app, and do not require a Royal TSX user to migrate their terminal habits wholesale.

### 17.9 a terminal component and the terminal engine: evaluate terminal components, do not fork them as the product

a terminal component provides a Swift terminal engine and an AppKit frontend, and its repository contains terminal examples; its current README warns that its 2.0 API differs from the 1.x branch, so old code examples must not be mixed in as-is. [R08]

the terminal engine provides the terminal engine and embedding examples and can be a candidate on performance and features. Both should be tested in practice with the user's Chinese input, the Codex / Claude TUIs, multi-line paste and the SSH / Docker resize chain, rather than chosen on the basis of marketing or screenshots. [R09]

**Recommended selection conclusion:** first build your own domain model and TargetAdapter; use an existing library for the terminal; borrow state detection from a reference project / a reference project; borrow the UI from a Mac agent console; borrow the control protocol from the official documentation and the designs of a reference project / a reference terminal. Do not bring in an entire mismatched backend just to save code in the first step.

---

## 18. Risks and open items that must be recorded

| Item | Current boundary | How development should handle it |
|---|---|---|
| User's Mac version / architecture | Not confirmed in this task | Determine the deployment target after probing the local machine; do not infer it from a UA |
| SSH host parameters, authentication method | Real targets are not provided in this document | Use the user's existing configuration and authorized test targets; do not ask for / copy private key contents |
| Container user, HOME, tmux socket | Not guaranteed to be consistent across containers | Configurable and probed per target, and part of identity |
| Agent CLI versions | Multiple versions may coexist | Version the rules and hooks; degrade for unknown versions |
| Shell wrappers / nested agents | Simple process names cannot settle every case | Multiple pieces of evidence plus restricted configuration; no promise that arbitrary nesting is always resolved automatically |
| Existing tmux hooks / options | May change attach / detach behavior | Detect and explain; do not rewrite silently |
| Native single-pane mirroring | Technically more complex than plain attach | Prototype first; do not claim full TUI support with an incomplete parser |
| Precise state with no remote helper at all | Not guaranteed to be achievable for every agent | Basic recognition + unknown; enhancements authorized separately |
| Reference code licenses | a Mac agent console noncommercial, a reference project TBD, a reference project split licensing | Avoid direct copying by default; maintain an inventory of dependencies and provenance |
| Commercialization / open source / App Store | Not specified by the user | Do not decide on the user's behalf; for now keep dependency choices and packaging strategy adjustable |

There is no need to halt all development because of the open items above. Architecture, tests and local prototypes that do not depend on real credentials can be completed first; only parameters that genuinely affect permissions, security or real connections need to be provided by the user before the corresponding acceptance step.

---

## 19. Deliverables checklist

The repository should contain at least the following. Names may be adjusted, but the responsibilities and reproducibility must not be omitted.

```text
README.md                      # Build, launch, basic configuration, limitations
AGENTS.md                      # This project's hard constraints and development conventions
LICENSE                        # License chosen only for code this project owns the rights to
THIRD_PARTY_NOTICES.md         # Third-party sources and licenses
App/                           # macOS UI and entry point
Packages/ or Sources/Core/     # Transport, targets, tmux, detection, domain model
Tests/                         # Unit, protocol and integration tests
Fixtures/                      # Redacted test data, annotated with provider versions
scripts/                       # Build and isolated tests; no production cleanup commands
docs/
  requirements.md              # This document and subsequent explicit changes
  architecture.md              # The actual implementation, not an outdated design
  decisions/                   # ADRs for terminal engine, connection mode, identity and security
  references.md                # Projects actually read / reused, with pinned commits
  compatibility.md             # Versions actually tested and degradation behavior
  test-report.md               # Results per T-xx and how to reproduce them
  performance.md               # CPU, RSS, connection count, network, soak results
  known-issues.md              # Unfinished / unverified items
```

Deliver a runnable `.app`, the source code and reproducible build steps. Release signing / notarization is done according to actual distribution needs; if it has not been done, say so explicitly, and do not dress up "launches on the development machine" as an officially distributable release.

The delivery report maps features and tests by F-xx / T-xx, stating which features were tested only with simulated data and which have been connected to real SSH / Docker / tmux. Screenshots of a development UI must not substitute for end-to-end evidence.

---

## 20. Execution instructions that can be handed directly to the development agent

> You will develop a macOS remote agent console for me. Please read this entire document, treat C-01 through C-10 as inviolable hard constraints, and treat the P0 requirements and the acceptance matrix as the completion criteria for the first version.
>
> My existing workflow is Mac → SSH host → docker exec into an existing container → existing tmux → Codex / Claude Code. I want a Mac agent console-style centralized display and real terminal interaction; I do not want backend, I do not want tmux migrated, and I do not want something that only manages tasks newly created by the app.
>
> First inspect the current workspace and the available build environment; give a short implementation plan, then start on the minimal vertical slice: native Mac window → system SSH → DockerTargetAdapter → list existing tmux → attach inside the app. Do not start by piling up lots of mock UI, and do not just produce yet another design document.
>
> For UI and module layering, reference a Mac agent console; for the tmux-first model, a reference project; for recognition logic, a reference project / a reference project; for control mode, the official tmux documentation, a reference project and a reference terminal; for the terminal component, evaluate a terminal component first and compare with the terminal engine if necessary. Check the current license and commit of any code you intend to reuse first. a Mac agent console's noncommercial license, a reference project's TBD license and a reference project's GPL / split licensing must not be ignored.
>
> Base mode does not install resident remote services, does not rewrite my SSH, shell, tmux or agent configuration, does not restart containers / Docker / agents, does not automatically add permission-bypass flags, and does not add a Docker virtual machine on the Mac. When real connection parameters are needed, use only targets I have explicitly provided or that exist in my trusted SSH configuration; do not guess credentials.
>
> Closing tabs, windows and the app must by default only disconnect; any remote destruction must be a separate, explicit operation. After a disconnect, first verify the target generation, then rediscover and attach; never automatically resend input or start a replacement process. When custom tmux configuration may affect keep-alive, explain it rather than modifying it silently.
>
> Automatic recognition first separates agent type from activity state, and supports an unknown state and evidence sources. Do not judge a task done merely because there is no output, and do not mix up different objects that share a directory / a name / `%0`. When a Claude child process has no independent PTY, a standalone terminal must not be faked for it.
>
> For each milestone, provide a buildable implementation, test results, known limitations and next steps; clearly mark items that could not be accepted in a real environment. First deliver reliable attachment to existing sessions, then do hooks, precise logs, notifications, file upload and native pane mirroring.

---

## 21. Sources and verification entry points

The following are entry points to public projects and official documentation, all checked on **2026-10-09**. The default branches in external links may change; the development agent should separately pin commits for actual code references. The recommended design, acceptance budgets and implementation order in this document are proposals for this project, not claims about capabilities the reference projects have already implemented.

| ID | Source | Scope of use in this document |
|---|---|---|
| [R01] | a Mac agent console repository / README | Product positioning, UI, UIKit and backend dependency |
| [R01L] | a Mac agent console LICENSE.md | a noncommercial license identifier and scope |
| [R02] | a reference project repository / README | tmux-first architecture, metadata opt-in, License TBD |
| [R03] | a reference project repository / README | Layered recognition, providers, state, incremental logs |
| [R03L] | a reference project LICENSE | MIT license |
| [R04] | a reference project repository | macOS terminal project and code entry points |
| [R04D] | a reference project Remote tmux Mirroring documentation | Control mode, object mapping, known limitations |
| [R04L] | a reference project LICENSE | Distinction between the default GPL and BUSL for a specific server directory |
| [R05] | a reference project repository / README | tmux discovery, log matching, web product form |
| [R05L] | a reference project LICENSE | MIT license |
| [R06] | a reference project repository | Desktop / tmux-adjacent product reference |
| [R06D] | a reference project Remote documentation | daemon / relay, data visibility, license statement on the website |
| [R07] | a reference terminal tmux Integration documentation | Native window mapping and detach / close semantics |
| [R08] | a terminal component repository / README | Swift / AppKit terminal component, API version notes |
| [R08L] | a terminal component LICENSE | MIT license |
| [R09] | the terminal engine repository / README | the terminal engine and embedding examples, repository license identifier |
| [R10] | Official tmux Control Mode wiki | `-C` / `-CC`, command replies, asynchronous notification protocol |
| [R11] | OpenBSD tmux manual | Sockets, object IDs, attach, environment and client flags |
| [R12] | OpenBSD ssh manual | SSH arguments, remote commands and terminal behavior |
| [R13] | OpenBSD ssh_config manual | SSH configuration, jump hosts, connection reuse and authentication-related options |
| [R14] | Official Docker container exec documentation | `-i` / `-t`, user, environment, lifecycle |
| [R15] | Official Docker container ls documentation | Container listing and formatted output |
| [R16] | Official Docker inspect documentation | Controlled field probing and formatting |
| [R17] | Official OpenAI Codex Hooks entry point | Optional enhancement layer; verify against the actual version at implementation time |
| [R18] | Official OpenAI Codex Advanced Configuration entry point | CODEX_HOME and config / state locations |
| [R19] | Official Claude Code Hooks reference documentation | Structured hooks, Stop and related event semantics |
| [R20] | Official Linux kernel `/proc` documentation | Process information and access boundaries |

[R01]: a Mac agent console
[R01L]: a noncommercial license
[R02]: https://github.com/org/a reference project
[R03]: https://github.com/org/a reference project
[R03L]: https://raw.githubusercontent.com/org/a reference project/main/LICENSE
[R04]: https://github.com/org/a reference project
[R04D]: https://a reference project.com/docs/remote-tmux
[R04L]: https://raw.githubusercontent.com/org/a reference project/main/LICENSE
[R05]: https://github.com/org/a reference project
[R05L]: https://raw.githubusercontent.com/org/a reference project/master/LICENSE
[R06]: https://github.com/org/a reference project
[R06D]: https://a reference project.cc/remote
[R07]: https://a reference terminal.com/documentation-tmux-integration.html
[R08]: https://github.com/org/a terminal component
[R08L]: https://raw.githubusercontent.com/org/a terminal component/main/LICENSE
[R09]: https://github.com/org/the terminal engine
[R10]: https://github.com/tmux/tmux/wiki/Control-Mode
[R11]: https://man.openbsd.org/tmux
[R12]: https://man.openbsd.org/ssh
[R13]: https://man.openbsd.org/ssh_config
[R14]: https://docs.docker.com/reference/cli/docker/container/exec/
[R15]: https://docs.docker.com/reference/cli/docker/container/ls/
[R16]: https://docs.docker.com/reference/cli/docker/inspect/
[R17]: https://developers.openai.com/codex/hooks
[R18]: https://developers.openai.com/codex/config-advanced
[R19]: https://code.claude.com/docs/en/hooks
[R20]: https://docs.kernel.org/filesystems/proc.html

---

**Final product boundary: this app manages "visibility of, and interaction with, the terminals and agents I already run remotely"; it does not take over their lifecycle. First get reliable finding, correct entry and safe disconnection right, then add smart recognition and convenience features.**
