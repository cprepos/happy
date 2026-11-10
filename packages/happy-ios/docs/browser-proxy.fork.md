# Remote-only browser and artifact proxy: fork notes

These are this fork's (`cprepos/happy`) changes to `browser-proxy.md` in this
directory, which is kept as upstream's text so upstream merges apply cleanly.
Each section says where it goes and whether it replaces upstream's text or adds
to it. Where this file and `browser-proxy.md` differ, this file wins.

## Routing: Happy CLI (relay) chat links (added to upstream's Routing list)

This bullet goes in Routing after the first bullet (a chat link uses that
chat's workspace), before the `CONNECT /v0/workspaces/:id/proxy` bullet.

- A Happy CLI (relay) chat has no workspace on any agent connection, so its
  links go through a paired computer's host fallback workspace, chosen by
  `LegacyLinkRoute` when the link opens. The chat's machine is its
  `metadata.machineId` in the account's machines, named as home names it
  (`SessionList.hostName` over `MachineName`: `displayName`, else
  `happyAgent.nodeName`, else `host`, else the session's own
  `metadata.host`). In order:
  1. The paired computer whose node name equals the machine's
     `metadata.happyAgent.nodeName` (compared as in 3). happy-cli's daemon
     publishes it from the Happy Agent sharing its `~/.happy`, so it is the
     same computer whatever either is called. Older daemons omit it.
  2. A computer the person picked for that machine before, while it is still
     paired. One no longer paired is dropped from local settings
     (`relayLinkComputers`, relay machine id to agent connection id) and the
     rest decides again.
  3. The one paired computer whose name matches the machine's, trimmed and in
     any case, both read through `AgentName.friendly` as computers are shown
     (a relay `prep-pro`, `Prep Pro` or `prep-pro.local` matches the node
     `prep-pro`).
  4. Otherwise, with at least one paired computer (no match, or several), the
     person is asked before anything loads: "Open links from <machine>
     through", one button per paired computer by name, and Cancel. The pick is
     kept for the machine; the Machine screen shows "Links open through
     <computer>", and tapping that row (Ask Next Time) forgets it.
  5. No paired computer (revoked ones and hidden ones don't count): the
     unavailable state, as above. There is no default computer.

## The browser screen: pull to refresh (replaces upstream's sentence)

In The browser screen, upstream's last sentences "There is no pull to refresh
(Steve, for both apps); the header's button reloads." are replaced, in this
fork, by the text from "Until it paints" on:

safe area, so nothing moves when the header appears. Until it paints, the
screen's surface shows through (`isOpaque = false`). Pull to refresh
reloads (this fork keeps it; upstream has only the header's button).

## Live browser card (added after The browser screen, before Native artifact viewer)

An agent's text that links `http://localhost:6090/live/<id>`, or the bridge's
LAN listener `http://192.168.2.72:6090/live/<id>` for a chat on another computer
(the id 32 lowercase hex digits; `LiveBrowserLink`, whose `origins` are the one
list of both) gets a card in the transcript
(`LiveBrowserCardView`) in place of the link: bare, `<link>` or `[words](link)`,
never in code, once per id. The card polls `GET /live/<id>/state` and
`GET /live/<id>/frame.jpg` (read by its bytes; the bridge serves PNG) every
1.5 s through `BrowserFetcher`, in the chat's workspace, only while it is on
screen. It stops when the bridge says `done` (`session_closed` among them),
`404` (ended) or `410` (expired), or the workspace refuses CONNECT with `501` (a
container workspace: the browser runs on the host). While the state is
`takeover` the card says why; a tap opens the live page in the browser screen,
whose header then has a Done that POSTs `/live/<id>/done` the same way and
closes the screen.

## Contract gaps and limits: host fallback (replaces upstream's paragraph)

This replaces upstream's paragraph starting "The daemon exposes no unscoped
host CONNECT endpoint" (whose middle says legacy relay chats can only use the
active agent connection's host fallback or show the unavailable state).

The daemon exposes no unscoped host CONNECT endpoint, so host fallback needs a
local host workspace. A Happy CLI chat's links reach a computer only through
that fallback, on the computer `LegacyLinkRoute` picks (Routing above), never
through the relay. No device-local localhost or public fallback occurs.
