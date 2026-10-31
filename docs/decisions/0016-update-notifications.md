# ADR 0016: Update Notifications

Date: 2026-10-31. Status: accepted.

Checked from this Mac, through its system proxy:
- GitHub's REST API, without a token, answered 403 "API rate limit exceeded" for the proxy's exit address, which many people share.
- `https://github.com/superpung/agentmux/releases.atom` answered 200 with all six releases, newest first, each with its version as the title, its page as the link, and its notes as HTML.

## Context

AgentMux had no way to learn of a new release. The usual answer, a framework such as Sparkle, updates in place but needs a signed, notarized app and shows its own windows. AgentMux is ad-hoc signed, and the user does not want the app to interrupt with an update window.

## Decision

**Tell, don't install:**
- A newer release is announced in a notification: "AgentMux 0.4.0 available", with the lead phrases of its changelog items as the body.
- Clicking it opens the release page, which has the notes and the download.
- Nothing is downloaded or replaced, and no window opens.

**When:**
- 30 s after launch, then once a day while the app runs.
- Each version is announced once.
- **AgentMux ▸ Check for Updates…** checks at once and always answers, also when up to date or when the check failed, in a notification as well.
- Settings ▸ General ▸ **Check for updates** (on by default) turns off the automatic checks.

**Where:**
- From the repository's release feed (`releases.atom`) on github.com, not its API: the API's limit without a token is shared by everyone behind the same address and was already used up.
- The highest version in the feed wins. Tags that are not plain versions (a pre-release such as `0.4.0-beta.1`) are skipped.
- Parsing and version comparison live in `AgentMuxCore` (`ReleaseFeed`) and are tested against the feed's shape.

## Consequences

- The app contacts github.com about once a day. The request carries the app's version in its user agent and nothing else about the user.
- A build from source of an unreleased version is never offered an older one, since only a higher version counts.
