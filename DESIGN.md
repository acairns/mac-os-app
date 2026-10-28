# Design System: /dev/null for Mac — The Workspace

This is the design system for the Mac app at full parity with the web. It extends the web's system in `../dev-null.sh/DESIGN.md` and the tokens in `Sources/DevNull/Design/DesignSystem.swift`. Where this file is silent, the web's DESIGN.md applies. Where they disagree on something Mac-specific (window chrome, menus, keyboard, type sizes), this file wins. Product rules and vocabulary come from `../dev-null.sh/PRODUCT.md` and are never overridden here.

## 1. Overview

**North star: "One list of everything you read."** The app is a workspace in the Slack sense. One sidebar lists every place you can read: the three logs, your remotes and orgs, and your own pages. The middle shows whatever you picked. Replies open in a right-hand pane so the log never moves. A remote is a sidebar item just like a log. Nothing in the app is a mode you have to find.

The visual register stays the web's: a well-lit terminal, flat surfaces cut by hairlines, one blue that means "you can act here" or "you are here", six lane colors that only ever mark a person, and a literal `git log --graph` rail down every list of commits. The Mac layer adds what a Mac app owes its users: a real source list, a unified toolbar, an inspector, native menus for every action, the standard Settings window, and complete keyboard control.

**Key characteristics**

- One `NavigationSplitView` window: **sidebar**, **center**, and a **replies pane** (`.inspector`).
- The sidebar holds three sections: **Logs**, **Remotes**, **You**.
- Every list of commits sits on the graph rail. Every notification sits on the hollow-node rail.
- Lane color is identity, blue is action. They never trade jobs.
- Mono for what a machine prints, sans for what a person writes.
- Remotes work exactly as they do today. The chat view, composer, lightbox, menus and info sheet are reused, not redrawn.

## 2. Principles

1. **The sidebar is the map.** Everything a person can read is a sidebar item. A feature that has no sidebar item is reached from the thing it acts on (a commit's actions, a profile's menu), never from a hidden mode.
2. **Reading never moves.** Opening a thread, a preview or a menu never scrolls, reflows or replaces the log. Threads go to the replies pane. Profiles and commit pages push in the center with back/forward.
3. **Quiet counts.** A log's new-commit count is a muted mono number, never a badge. Only things addressed to you (unread remotes, notifications, fetched requests) get the blue `CountBadge`. Nothing in the app is red except destruction.
4. **Native first, /dev/null second.** Use the system control whenever one exists (List, Menu, Toggle, Picker, Popover, Settings, Commands). Restyle it with DS tokens; never re-implement it.
5. **Same rules on every surface.** Limits, moderation states, visibility, mutes and blocks behave exactly as on the web, because the API enforces them. The app never hides or shows something the web would not.
6. **Nothing stored without a reason.** Messages, commits, images and drafts live in memory only. Besides a few preferences, nothing about anyone is written to disk on the Mac (see §15).

## 3. Window anatomy

### 3.1 Scenes

| Scene | Type | Purpose |
|---|---|---|
| Main | `WindowGroup("/dev/null", id: "main")` | The workspace. Multiple windows are allowed; each keeps its own selection and history. |
| Item window | `WindowGroup(id: "item", for: SidebarItem.self)` | "Open in New Window" for any sidebar item (a log, a remote, a profile). Same layout without the sidebar. |
| Commit window | `WindowGroup(id: "commit", for: Commit.ID.self)` | "Open in New Window" for a commit page. |
| Composer | `Window("New Commit", id: "composer")` | The standalone composer (⌘N), 560×360 default, resizable. |
| Settings | `Settings` | ⌘, (see §11). |
| About | existing `AboutWindow` | Unchanged. |

The default size is 1240×780, and the minimum stays 760×480. The toolbar style stays `.unified(showsTitle: false)`.

### 3.2 Columns

```
┌──────────────┬──────────────────────────────────────┬────────────────────┐
│ Sidebar      │ Center                               │ Replies pane       │
│ 220–300      │ min 440, flexible                    │ 320–440            │
│ ideal 248    │                                      │ ideal 372          │
│ DS.Colors    │ DS.Colors.surface                    │ DS.Colors.surface  │
│ .sidebar     │ (chat: DS.Colors.chat)               │                    │
└──────────────┴──────────────────────────────────────┴────────────────────┘
```

- **Sidebar.** `NavigationSplitView` sidebar column, `.navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 300)`. `⌃⌘S` toggles it (system default).
- **Center.** The detail column. Lists of commits fill the column, but commit text never runs wider than `DS.Metrics.readingMeasure` (640). The rail stays at the column's leading edge, and extra width goes to the trailing side.
- **Replies pane.** `.inspector(isPresented:)` with `.inspectorColumnWidth(min: 320, ideal: 372, max: 440)`, toggled by the toolbar button and `⌥⌘0`.

**Narrow windows.** Collapse in this order and never earlier:

1. When the window can't fit the sidebar's ideal width, center min 440 and the open replies pane, the sidebar auto-hides (`columnVisibility = .detailOnly`) and its toolbar toggle stays.
2. If it's still too narrow, the replies pane overlays the center (the inspector's own compact behavior) with a hairline leading edge and `DS.Elevation.floating`.
3. The selection is never lost. Widening the window restores the columns that were visible.

### 3.3 Toolbar

A single unified toolbar spans all columns. The items, from leading to trailing:

| Position | Item | Notes |
|---|---|---|
| Sidebar column | Sidebar toggle, **Compose** (`square.and.pencil`) | Compose is a menu with *New Commit… ⌘N*, *New Remote… ⇧⌘N*, *New Org… ⌥⇧⌘N*. |
| Center, leading | **Back / Forward** (`chevron.left` / `chevron.right`) | ⌘[ / ⌘]. Disabled at 40% opacity when there's nothing to go to. A long press shows the history menu. |
| Center, leading | **Title block** | A 13.5pt semibold title with a 14pt SF Symbol, over a `DS.Fonts.monoMeta` subtitle (see §6 for each destination). |
| Center, trailing | **Search** (`.searchable` placement `.toolbar`, 300pt) | Placeholder "Search people, commits, remotes". Shows a `⌘K` kbd. Clicking it or pressing ⌘K opens the Switcher (§9.16). |
| Center, trailing | Destination actions | 0–3 `IconButtonStyle` buttons. Example: a remote shows its stacked member avatars and an info button. |
| Trailing | **Replies pane toggle** (`sidebar.right`) | Highlighted on the wash while the pane is open. |

Toolbar buttons are 28pt `IconButtonStyle` with 16pt symbols in `DS.Colors.inkMuted`. On hover and when on, they get the `DS.Colors.wash` fill and `DS.Colors.ink` glyph. Every toolbar item can be customized (`.toolbar(id:)`), and none of them only exists in the toolbar: each is also a menu command.

## 4. Tokens

All existing tokens in `DesignSystem.swift` stay. These are the additions, added to the same `DS` enums so every new view draws from one place.

### 4.1 Colors (additions)

| Token | Light | Dark | Use |
|---|---|---|---|
| `DS.Colors.sidebar` | `0xF1F2F4` | `0x1C1C1F` | Sidebar background, when the system material is not used (see note). |
| `DS.Colors.selectionSoft` | = `primarySoft` | = `primarySoft` | Selected commit row (the one whose thread is in the replies pane). |
| `DS.Colors.focusRing` | `primary` @ 50% | `primary` @ 50% | j/k focus ring and keyboard focus. |

Note: by default the sidebar uses the system's sidebar material (`.listStyle(.sidebar)`, vibrancy on). `DS.Colors.sidebar` is the fallback for Increase Contrast and Reduce Transparency, and for drawing over it (stacked-avatar knockouts).

Existing roles to keep using: `shell` (graph node holes, page ground of sheets), `surface` (center and replies pane), `chat` (remote background), `hairline`, `rail` (rail-gray segments, input strokes), `wash` (hover), `primary` / `primaryFill` / `primarySoft`, `destructive`, `inkFaint` (decorative glyphs), `lane(_:)`.

**Status colors.** Like the web console, status colors (`success` = lane-1 green, `warning` = lane-5 ochre) exist only for moderation status labels on your own pending or rejected commits. They always come with a word, never color alone, and never mark a person.

### 4.2 Typography (additions)

SF replaces Geist, and SF Mono replaces Geist Mono. Sizes are one step smaller than the web, as in the rest of DS.

| Token | Spec | Use |
|---|---|---|
| `DS.Fonts.commitBody` | 14 regular, line spacing 3 | Commit bodies in the log, starred, profile and search. |
| `DS.Fonts.threadBody` | 15 regular, line spacing 3 | The commit at the top of the replies pane and on the commit page. |
| `DS.Fonts.replyBody` | 13.5 regular | Replies in the pane and the commit page. |
| `DS.Fonts.commitAuthor` | 13 semibold | The author name in commit headers. |
| `DS.Fonts.sidebarItem` | 13 regular; 13 semibold when unread | Sidebar rows. |
| `DS.Fonts.sidebarSection` | 11.5 semibold, `inkFaint` | "Logs", "Remotes", "You". |
| `DS.Fonts.workspace` | 16 bold, tracking −0.5 | The "/dev/null" workspace name. |
| `DS.Fonts.toolbarTitle` | 13.5 semibold | Toolbar title. |
| `DS.Fonts.profileName` | = `DS.Fonts.title` (20 semibold) | Profile header. |

Mono roles stay as they are: `monoHandle` (12) for handles, `monoCaption` (11, tabular) for times, hashes and counts, `monoMeta` (10.5) for subtitles and stamps, `monoFatal` for `fatal:` lines, `code` (12) for code blocks.

**The Machine Speaks Mono Rule** applies unchanged. Set handles, short hashes, relative times, counts, the character countdown, `HEAD@{last visit}`, `stash@{0}`, `fatal:` lines and `null` values in mono. A human sentence is never set in mono, and that includes sidebar labels, buttons and empty-state sentences.

### 4.3 Metrics (additions to `DS.Metrics`)

| Token | Value | Use |
|---|---|---|
| `railWidth` | 44 | The rail column of every commit row. |
| `railLine` | 2 | Rail segment width. |
| `node` | 14 | A graph node; 2pt lane ring, `shell` hole. |
| `nodeTop` | 15 | Node's top offset in a commit row (center at y = 22). |
| `commitAvatar` | 36 | The avatar in a log row. |
| `threadAvatar` | 40 | The avatar of the commit at the top of the replies pane. |
| `replyAvatar` | 28 | The avatar in a reply row. |
| `notificationNode` | 32 | The hollow notification node holding a 14pt type icon. |
| `sidebarRow` | 28 | Sidebar item height. |
| `sidebarAvatar` | 18 | A person's avatar in the sidebar. |
| `readingMeasure` | 640 | The max width of commit text. |
| `commitGutter` | 16 | Trailing padding of commit content. |
| `bodyIndent` | 44 | The body and actions indent under the avatar (36 avatar + 8 gap). |
| `previewWidth` | 304 | The user preview popover. |
| `switcherWidth` | 560 | The ⌘K switcher. |
| `activityCell` | 10, gap 2 | Activity graph cells. |

Radii stay `DS.Radius`. Use `sm` (4) for chips and status labels, `md` (6) for controls, badges and code, `lg` (8) for embeds, link cards, the reply composer, popovers and sheets, and `xl` (12) only for the switcher panel. Avatars, nodes and lane dots are circles.

### 4.4 Motion

Reuse `DS.Motion`. Use `quick` for hover and press, `standard` for popovers, the replies pane and the new-commits button, and `slide` (220ms expo-out) for the sidebar selection and tab underlines. Wrap every animation in `DS.Motion.respecting(reduceMotion, …)`.

The graph has three moments of its own, and they are the only decorative motion:

- **Node pop.** When your commit lands, its node scales 0.4 → 1 with `standard`.
- **Rail draw.** When "↑ N new commits" is clicked, the new segments draw downward over 220ms.
- **rm.** When you delete, the row prints `rm a1f3c9e` in mono and collapses with `standard`. This is the web's commit-deletion collapse, and it keeps the scroll anchor.

### 4.5 Elevation

The app stays flat. Use `DS.Elevation.floating` only for the new-commits button, the scroll-to-bottom button and an overlaying replies pane. Use `DS.Elevation.popover` for the user preview, the switcher and toasts. Commit rows, embeds and panes never cast a shadow (**The No Cards Rule**).

## 5. Sidebar

### 5.1 Structure

```
/dev/null ▾                      @nunomaduro     ← workspace header
▾ Logs
   ⟟ Following                          3        ← quiet mono count
   ◷ Latest
   ↗ Trending
▾ Remotes                               +
   ◐ /dev/null core                     (3)      ← CountBadge
   MO Maya Okafor                       📌
   LM Leo Martins                  fetched       ← chip
   … up to 5 recent
   ⋯ All Remotes                        (1)      ← unread outside the list
   ▭ Stashed                             1
▾ You
   🔔 Notifications                     (5)
   ☆ Starred
   ▦ Scheduled                           2
   ◯ Profile
──────────────────────────────────────────
NM Nuno · polling · 30s                 ⚙    ← footer
```

It's built as a `List(selection: $navigation.item)` with `.listStyle(.sidebar)`. Each section is a `Section(isExpanded:)` with a disclosure chevron, and the expanded state is stored in `@AppStorage` per section.

### 5.2 Workspace header

"/dev/null" is set in `DS.Fonts.workspace` with a 12pt `chevron.down`, and the handle in `monoHandle` muted on the trailing side. It's a `Menu`:

- *Your Profile*
- *Settings… ⌘,*
- *Check for Updates…* (non-App Store builds)
- Divider, then *Open /dev/null on the Web*, *Manage Devices…*
- For admins only: Divider, then *Moderation on dev-null.sh ↗* and *Operations on dev-null.sh ↗*. These open the browser; nothing admin renders in the app.
- Divider, then *Sign Out*

### 5.3 Item anatomy

Each item is 28pt tall, with a 16pt leading glyph or an 18pt avatar, the label in `DS.Fonts.sidebarItem` (truncating at the tail), then a trailing accessory. The selection is the system sidebar selection tinted `DS.Colors.primaryFill` with white text, which is today's `.sidebarSelection` treatment.

| Item | Glyph | Trailing accessory | Unread rule |
|---|---|---|---|
| Following / Latest / Trending | `point.3.connected.trianglepath.dotted`-style commit glyph / `clock` / `chart.line.uptrend.xyaxis` | Muted `monoCaption` count of commits newer than `HEAD@{last visit}`, capped at 99+. Following and Latest only. | Label goes semibold while the count is > 0. Never a badge. |
| Direct remote | Partner `Avatar` 18pt | `CountBadge` if unread; otherwise a `pin.fill` 11pt `inkFaint` if pinned; `bell.slash.fill` if muted | Label semibold while unread. |
| Org | `OrgAvatar` 18pt (two stacked 13pt discs) | Same as direct | Same. |
| Fetched request | Partner avatar | `fetched` chip (`monoMeta`, `wash`, radius `sm`) | Counts toward the Remotes section's "fetched" total. |
| All Remotes | `ellipsis.bubble` | `CountBadge` of unread remotes *not* listed above | — |
| Stashed | `archivebox` | Muted mono count | — |
| Notifications | `bell` | `CountBadge` of unread notifications | — |
| Starred | `star` | none | — |
| Scheduled | `calendar.badge.clock` | Muted mono count of queued commits | — |
| Profile | `person` | none | — |

### 5.4 Which remotes appear

The Remotes section lists, in this order:

1. Pinned remotes and orgs, ordered by their latest message.
2. Then the most recent unpinned ones, so the section shows at most **7** conversation rows.
3. A fetched request always shows, at the end of the list, even beyond 7.

Everything else lives under **All Remotes**. That opens today's full inbox (Open / Fetched / Stashed tabs, search, infinite list) in the center as a list. Selecting a row there opens its chat in place. The section's `+` button is the New Remote / New Org menu. If the user has turned Remotes off (`remotes == nil`), the section collapses to one muted row, "Remotes are off", that opens Settings → Remotes.

### 5.5 Item interactions

- **Click** selects. **⌘-click** or the context menu's *Open in New Window* opens it in an item window.
- **⌥↑ / ⌥↓** move to the previous or next sidebar item across sections, skipping headers. **⌃Tab / ⌃⇧Tab** move to the next or previous unread item. This keeps today's ⌥↑/⌥↓ muscle memory.
- **Drag** a remote within the pinned group to reorder it locally. Dragging a remote onto the pinned group pins it, and dragging it out unpins it (`PUT remotes/…/pin`).
- **Context menu on a remote:** Open in New Window, Pin/Unpin, Mute ▸ (For One Hour, Until Tomorrow, For One Week, Forever / Unmute), Stash / Pop, Mark as Pulled, Divider, Show Info, Divider, Block @handle… (destructive). This is the same set as today's `ConversationMenu`.
- **Context menu on a log:** Open in New Window, Mark All as Seen (moves `HEAD@{last visit}` to the newest commit).
- **Hover on a remote** prefetches it (`inbox.prefetch`) as today.

### 5.6 Footer

The footer is 44pt with a top hairline. It shows a 24pt avatar with the lane ring, the name (12.5 semibold) over `polling · 30s` in `monoMeta`, and a gear button that opens Settings. When a poll fails, the subtitle becomes `fatal: offline · retrying` and the app keeps the last data it had.

## 6. Center destinations

Each sidebar item has one center destination. The toolbar title and subtitle are:

| Destination | Title (symbol) | Subtitle (mono) |
|---|---|---|
| Following | Following (commit glyph) | `log · 3 new since HEAD@{last visit}`, or `log · up to date` |
| Latest | Latest (`clock`) | `log · polled 12s ago` |
| Trending | Trending (`chart.line.uptrend.xyaxis`) | `log · last 7 days` |
| Direct remote | Partner name | `@maya · typing…` or `@maya` |
| Org | Org name or members | `org · 4 members` |
| All Remotes | Remotes | `3 unread · 1 fetched` |
| Notifications | Notifications | `5 unread` |
| Starred | Starred | `48 commits` |
| Scheduled | Scheduled | `2 queued` |
| Profile / any profile | Name | `@maya` |
| Commit page | Commit | `a1f3c9e` |
| Search results | “query” | `commits by meaning · 14 results` |

**History.** Profiles, commit pages and search results push onto a per-window history stack (`NavigationStack` path inside the detail column). Selecting a sidebar item resets the stack to that item's root. Back and Forward walk the stack. History is never persisted to disk.

### 6.1 Log (Following, Latest, Trending)

A `ScrollView` of a `LazyVStack(spacing: 0)` holds, from the top:

1. **Staged composer** (§9.9): the hollow node, the placeholder "What did you ship?", the tool row, the countdown and Commit.
2. **"↑ N new commits" button.** It floats under the toolbar, centered on the column at y = 52 below the top of the list. It's `DS.DSButtonStyle` primary small, its count in mono, with `DS.Elevation.floating`. It appears only when new commits arrived above the visible area, and it previews up to three author avatars (18pt, overlapped −4) with a `+N` disc for more. Clicking it scrolls to the newest commit and draws the rail (§4.4). It disappears once the newest arrival is visible.
3. **Commit rows** (§9.1), with **day markers** wherever the local day changes, and one **HEAD marker** (§9.6) between the commits that arrived since your last visit and the first one you'd already seen.
4. **Paging:** 20 commits per page. Skeleton rows (§9.18) show while the next page loads, after the 300ms skeleton delay.
5. **Root node** at the end of history: a hollow node with no tail, then "That's the root commit. There's nothing before it." in muted sans.

**Polling.** Following and Latest poll every 30s while the window is visible and the app is active, and every 5 min in the background. A poll never reorders or moves what's on screen. New arrivals are inserted above with the scroll anchor kept (`scrollPosition(id:)`), and they're announced only by the button and the sidebar count. Trending doesn't poll. It reshuffles on open and on ⌘R, and keeps the same draw while you scroll.

**Last visit.** `HEAD@{last visit}` is the newest commit time seen per log. It's held in memory and in `UserDefaults` as a single timestamp per log. It's a preference-sized value, not content (§15).

**Empty states** (`EmptyState`):

- Following with no follows: `fatal: your log is empty`, "Follow a few developers and their commits land here." Below it, the three starter suggestions (a commit row each with a Follow button), as on the web.
- Load failure: `fatal: could not fetch the log`, followed by the error sentence and a "Try Again" link button.

### 6.2 Commit page

The commit page opens from ⇧⌘↩ on a focused commit, from "Open Commit Page" in a row's menu, or by clicking its hash or time while holding ⌘. It pushes onto the center history.

- Visible ancestors (up to 20) stack above on one continuous rail, with deleted ones as tombstones (§9.5).
- The commit itself uses `threadAvatar` 40 and `threadBody` 15, and its stamp line reads `14:28 · Tue, Oct 27, 2026 · commit a1f3c9e`.
- Then the full action row (§9.4).
- Replies follow, threaded as on the web: children indent one rail level, at most three levels, then "Continue thread →".
- Then *Quoted by* (compact rows) and *Related commits* (compact rows, muted section label "related · by meaning").
- The inline reply composer (§9.10) sits under the commit.

### 6.3 Remote (direct or org)

This destination is today's `ChatView`, unchanged: bubbles, day pills, reactions, replies, images, link cards, voice notes, receipts, typing, pinned bar, access banner and composer. While a remote is selected, the replies pane becomes the **info pane**. It shows today's `ThreadInfoView` content laid out as a pane: members with roles, mute, stash, pin, leave or block. The toolbar's info button and ⌘I toggle it, and it replaces the old info sheet.

Picking a remote marks it read exactly as today. Remote banners and sounds still skip the remote being read in a key window.

### 6.4 All Remotes

Today's `SidebarView` content, moved into the center: the Open / Fetched / Stashed `SidebarTabs`, the "Search remotes" field, `ConversationRow`s, and the "Start a conversation" suggestions while searching. Selecting a row pushes its chat. The rows, tabs, empty states and context menus stay exactly as today.

### 6.5 Notifications

The toolbar subtitle shows the unread count. Under the toolbar is a tab row: All, Replies, Quotes, Stars, Mentions, Follows, Moderation. These are page tabs (§9.15). The selected filter is remembered in `@AppStorage`, and the unread count follows the filter.

Rows sit on the hollow-node rail (§9.7). Grouped rows (stars per commit, follows per day, replies and mentions per thread) expand in place with a disclosure. Clicking a reply, quote or mention row opens its commit in the replies pane. A star group opens the commit page. A follow row opens the profile and has **Follow back** inline. Opening Notifications marks all read, as on the web. Level-up rows show under All only.

### 6.6 Profile

The profile header comes first:

- an 80pt avatar with a 2pt lane ring offset 4pt;
- the name in `profileName`, a mono handle led by a lane dot, and a "Follows you" chip;
- the bio, with links and mentions;
- metadata with 14pt symbols (location, site, joined);
- mono counts paired with sans labels ("312 commits", "1,204 followers", "188 following"), where the followers and following counts push lists;
- a live marker when streaming (§9.14).

Actions sit on the trailing side:

- Your own profile: an **Edit on GitHub** outline button, opening GitHub.
- Others' profiles: **Follow** (primary) or **Following** (outline, "Unfollow" on hover, but only after the pointer has left once since the click), **Push** (outline, opens or creates the direct remote), and `…`: Mute, Block…, Copy Profile Link, Open on the Web.

Then the **activity graph** (§9.13), the **streak strip**, the **rank and achievements** (§9.14), the **pinned commit**, and tabs **Commits · Replies** (and **Starred** on your own) holding a log on the rail. Profile content is read-only mirrored from GitHub; nothing on the Mac edits identity.

### 6.7 Starred

A log of saved commits, newest star first, on the rail. Rows are the standard commit row; unstarring keeps the row until you navigate away, so the list never jumps under the pointer. Empty state: `fatal: no starred commits`, "Star a commit and it waits for you here."

### 6.8 Scheduled

The queue of scheduled commits. Each row is a **staged node** (hollow, dashed tail) with the body, its images and poll as they'll post, the send time in mono (`today 18:00`, `Thu 29 · 09:30`) in your timezone, and the trailing actions **Post Now**, **Edit Time…** (a date picker popover) and **Cancel** (destructive, inline confirm in the button's slot). Empty: `fatal: nothing scheduled`, "Pick a time in the composer's calendar button to queue a commit."

### 6.9 Search results

Commit search by meaning is shown when the switcher's "Search commits for “…”" row is chosen (or ⌘↩ in the switcher). It's a log of results on the rail, in relevance order, without day markers. The muted header line reads `commits by meaning · may miss some`. Queries need 3–100 characters, as on the web; the switcher shows the rule inline rather than an error.

## 7. Replies pane

The `.inspector`. It has two modes and nothing else:

| Center shows | Pane shows | Opens when |
|---|---|---|
| A log, Starred, Profile, Search, Notifications | **Thread** of the selected commit | Clicking "N replies" or Reply, pressing `o` or `r`, clicking a reply notification |
| A remote | **Info** for that remote (§6.3) | ⌘I, toolbar info button |

**Thread mode** is built like this:

- **Header (44pt pane head).** "Thread" (semibold) and the mono short hash, then "in Following" in muted sans, then a close button (Esc).
- **The commit.** The author header (40pt avatar with lane ring, Follow/Following on the trailing side) and the body in `threadBody`. Under it the stamp `4m · Tue, Oct 27 · commit a1f3c9e` in `monoMeta`, then the full action row.
- **A divider line** reading `3 replies` in mono.
- **Replies:** `replyAvatar` 28, a 1pt `rail` guide line connecting the avatars, the name, mono handle and time, a `bot` chip for bots, and the body in `replyBody`. Each reply has a compact action row: star with count, reply, copy link.
- **The reply composer** is pinned to the bottom (§9.10).

The pane follows the selection: selecting another commit's replies swaps its contents with a 120ms crossfade and never animates the width. Closing the pane clears the selected-row tint in the log. The pane's open state is per window, remembered for the session.

## 8. Remotes regressions to guard

Everything the shipped app does stays, in the same places relative to the chat:

- Requests (fetched) with Merge / Drop.
- Stash / pop, pins and timed mutes.
- Pull receipts and typing.
- Reactions with the emoji catalog.
- Replies, images with the lightbox, link cards and voice notes with speed and volume.
- Pinned messages, the access banner and drafts per remote.
- Notification banners with Reply and Mark as Pulled actions, never showing message text.
- ⌘↓ to jump to the newest message, and ⌥↑/⌥↓ between remotes (now between sidebar items).

## 9. Components

### 9.1 CommitRow

```
│ rail 44 │ content (trailing padding 16, bottom hairline starts after the rail)                │
│    ○    │ [36 avatar] Name  @handle · 4m                                            a1f3c9e   │
│    │    │             body at 14pt, pre-wrapped, max 640 wide, folded after 280 chars / 8 lines│
│    │    │             [images] [link card] [quote] [poll]                                    │
│    │    │             ☆ 24   💬   ◔◔◔ 3 replies  last 1m                              🔗  ⋯   │
```

- **Padding.** Vertical padding is 10pt. The header row is centered on the avatar, and the body and actions are indented by `bodyIndent`.
- **Header.** `commitAuthor` name, `monoHandle` muted handle, a middle dot and `monoCaption` relative time (a link to the commit page). The short hash goes on the trailing side in `monoCaption` muted, and is hidden below 520pt of column width. It shows "↳ replying to @handle" in muted sans above the header for a reply that surfaces in a log.
- **Status.** Pending and rejected commits are visible only to their author and show a `StatusLabel` ("pending", or "not approved" with the reason in the menu) after the time.
- **Fold.** Bodies longer than 280 characters or 8 lines fold behind a "Show more" link button, never cutting through a code block.
- **States:**
  - hover: `wash` behind the content area, never the rail;
  - **focused** (j/k): a 2pt `primary` leading bar inside the content plus `wash`;
  - **selected** (its thread is in the replies pane): `selectionSoft`;
  - **deleting**: the `rm` collapse (§4.4).
- **Author highlight.** Hovering the node, avatar, name or handle fades every other author's nodes and segments to 30% over 200ms.
- **Double-click** opens the replies pane. **Return** on a focused row opens the commit page.
- **Context menu:** Reply, Quote…, Star/Unstar, Give a Pastel (when pastéis mode is on), Divider, Copy Link, Open Commit Page, Open in New Window, Translate (when the body isn't in your language), Divider, Pin to Profile / Unpin (own), Report… (others), Delete… (own, destructive), Divider, Mute @handle, Block @handle….

### 9.2 Graph rail

The rail is drawn with a `Canvas` or `Path` in each row's 44pt rail column so it scrolls with the row. Each row draws:

- **Above the node:** a 2pt segment from the row's top to the node, in the *previous* row's author lane (`rail` for the first row under the composer).
- **The node:** a 14pt circle at x = 15, y = 15. Its fill is `shell`, and its 2pt ring is the author's lane.
- **Below the node:** a 2pt segment from the node to the row's bottom, in this author's lane. It's omitted on the root.

Markers and skeletons continue the segment in the lane above without a node. Rows are separated by a 1pt `hairline` that starts at x = 44, so the rail is never crossed (**The Unbroken Rail Rule**). Lanes come from `User.lane` through `LaneColor.of(_:)`, so never compute them locally.

### 9.3 Commit body

Plain text, pre-wrapped, with:

- **Mentions** (`@handle`): primary, with the user preview on hover.
- **URLs:** primary, opening in the default browser.
- **GitHub references** rendered as `owner/repo#123`: primary, in mono at body size −1.
- **Inline code:** mono on `wash`, radius `sm`.
- **Fenced code blocks:** `DS.Fonts.code` on `wash`, radius `md`, 10/12 padding. They scroll horizontally, show syntax highlighting with neutral ink tones (no lane colors), and have a copy button on hover. Copying a folded block copies the whole block.
- **Emoji** as text.

Selectable with `.textSelection(.enabled)`. Reuse `MessageText`'s link detection where it applies.

### 9.4 Action row

The action row holds, from leading to trailing:

- **Star:** a 15pt outline in muted ink, filled `primary` once starred, with the count in `monoCaption` when ≥ 1. It's optimistic, and rolls back on failure with a toast.
- **Reply:** a bubble icon. It opens the replies pane with the composer focused.
- **Replies:** "N replies" in `primary` sans, with up to three replier avatars (18pt, overlapped −4, knocked out by the row background) and `last 1m` in `monoMeta` `inkFaint`. Hidden at 0.
- **Copy link** on the trailing side: a muted link icon. It swaps to a check for 2s and shows the toast `Copied link to a1f3c9e`.
- **More** (`…`): the context menu.

The replies pane and the commit page show the **full row**: star, reply, quote with count, pastéis with count (opt-in), translate, copy link, more. Every button is a native `Button` with `.help("Star (s)")`-style tooltips and an accessibility label that includes the count.

### 9.5 Tombstone

The tombstone keeps the rail, with a dashed `rail` 36pt circle where the avatar was. It reads `[deleted]` in mono, then "This commit was deleted." in muted sans. It keeps its replies toggle but has no Reply.

### 9.6 Markers

- **Day marker:** the rail continues without a node, and the label "Today", "Yesterday" or "Tue, Oct 13" is set in `monoCaption` muted, with 6pt vertical padding.
- **HEAD marker:** the same row with a muted `HEAD@{last visit}` and a dashed `rail` hairline running to the trailing edge.

### 9.7 NotificationRow

The rail column is 52pt, with a 2pt `rail` line and a 32pt hollow node holding the type icon:

| Type | Icon |
|---|---|
| follow | `person.badge.plus` |
| reply | `bubble.left` |
| quote | `arrow.2.squarepath` |
| star | `star` |
| mention | `at` |
| approved | `checkmark` |
| rejected | `xmark` |
| level | `chevron.up.2` |

The content shows up to five 24pt avatars overlapped, a sentence with bold names ("Priya Raman and 8 others starred your commit"), the time in mono, and the excerpt of the commit in muted 13pt (two lines). Unread rows get a 6pt `primaryFill` dot on the trailing side. A rejection shows `reason: off-topic` in mono and never names a moderator.

### 9.8 Avatar, lane ring, OrgAvatar

Reuse `Avatar` and `OrgAvatar`. Add `.laneRing(user, width: 2, gap: 2)`, which draws the lane ring offset from the surface behind it. Lane rings appear on the profile header, the replies-pane commit and the user preview only, never in lists.

### 9.9 Commit composer

The composer has two presentations of one view:

- **Staged** at the top of a log.
- **Window:** ⌘N, or the Compose menu.

**Staged.** A hollow node is drawn on the rail, filling with your lane once the body has a character, with a dashed `rail` tail. The field is borderless `DS.Fonts.composer` (15), "What did you ship?". It grows to 12 lines, then scrolls. The tool row holds:

- Image (`photo`): file picker, or drag & drop onto the composer or anywhere on the log. Up to the web's image limit, each with a description field.
- Poll (`list.bullet`): inline poll editor, 2–4 options and a duration. It can't be combined with a quote.
- Preview (`eye`): swaps the field for the rendered commit in the same box, never shorter, so the counter row stays put. The URL that will unfurl shows in a dashed box with mono URL and "Unfurls into a link card".
- Schedule (`calendar`): a date picker popover. Once a time is set, the Commit button reads "Schedule", with the time in mono beside it.
- The countdown on the trailing side: `monoCaption`, from 4000. It turns `destructive` at 0.
- Commit (`DSButtonStyle` primary, disabled at 50% while empty), with a ⌘↩ hint.

`c` focuses the staged composer. Esc blurs it and keeps the draft. When a draft returns after navigation, `stash@{0}` shows in mono on the leading side of the tool row, with a muted "drop" link button.

**After committing.** The toast `[log 7be20d4] Postgres 18's async I/O…` appears, set in mono with the body truncated. The node pops, and the row appears at the top with a "pending" label until moderation approves it.

**Quote.** Quote… opens the window composer with the quoted commit embedded under the field (§9.11).

**Mentions and issues.** While typing `@` or `owner/repo#`, a popover of suggestions appears under the caret (`search/mentions`, `search/issues`). It's arrow-key navigable and accepted with Tab or Return.

### 9.10 Reply composer

A bordered box (`rail` stroke 1, radius `lg`, padding 9/10). The placeholder is "Reply to @maya…" and the tool row holds image, preview, `stash@{0}` when restored, the countdown and Reply. ⌘↩ sends and Esc returns focus to the commit. It has its own draft per commit.

### 9.11 Embeds

- **Quote:** a hairline box with radius `lg` and 8/10 padding. It shows a 20pt avatar, name, mono handle and time on one line, then the body clamped to six lines. The whole box is one button to the commit page, and it tints `wash` on hover. It never nests a second quote.
- **Link card:** the same box, with the URL in mono muted and the title in 13 medium, plus an optional image on the trailing side (64pt, radius `md`).
- **Embedded player:** link out instead of embedding.
- **Images:** the web's grid (1, 2, 3 or 4 tiles, 8pt radius, 2pt gaps), opening in the existing `Lightbox` with Quick Look (space bar) support.
- **Poll:** options as bars with percentage and count in mono, and your vote checked. Voting is a click before the poll closes. The footer shows `212 votes · 2d left` in mono.

### 9.12 User preview

Hovering an avatar, name or handle opens the preview, mouse only. It opens after 450ms, with 200ms of grace for the pointer to move into it. It's a 304pt `.popover` with:

- a 56pt avatar with the lane ring;
- Follow/Following on the trailing side;
- the name, mono handle with lane dot, and a "Follows you" chip;
- a 3-line bio;
- mono counts linking to followers and following;
- "Push" when Remotes allow it.

It never opens from a keyboard focus change. `K` on a focused row opens it from the keyboard.

### 9.13 Activity graph and streaks

Draw the activity graph as the web does. The window scales to the visible history (24 hourly cells, 7 day cells, 30 days, or 53 weeks of 7). The cells are `activityCell` squares with radius 2, the empty ones `wash`, and the filled ones the profile owner's lane at four opacities (25/50/75/100%). Labels are in `monoMeta`. Hovering a cell shows an inverted tooltip ("3 commits on Tue, Oct 14").

Under the graph is the streak strip, `longest streak 41 days · current 6`, with muted labels, ink numbers, and a lane dot before an active current streak.

### 9.14 Rank, achievements, live

- **Rank:** `/usr/local/maya — level 7 · sysadmin` in mono.
- **Achievements:** a row of chips in `monoMeta` (`fsck`, `grep`, `cron`), radius `md`. Clicking one opens a popover with its story.
- **Live marker:** a `destructive` ring on the avatar plus a "LIVE" chip, linking out to the stream.

### 9.15 Tabs and segmented controls

- **Page tabs** (notification filters, profile tabs): 13 medium labels, muted when inactive. The active tab is `ink` with a 3pt `primary` underline that hugs the label and slides with `DS.Motion.slide`. Use them where the web uses page tabs.
- **Segmented control:** the native `Picker(.segmented)`, only inside the Settings window and the All Remotes tabs (today's `SidebarTabs`).

### 9.16 Switcher (⌘K)

The switcher is a `.popover`-styled panel attached to the toolbar search field, `switcherWidth` 560, radius `xl`, max 60% of the window height and scrolling inside. It has a borderless 15pt input with an `esc` kbd, then sections:

- **People:** 28pt avatar, name, mono handle with lane dot, "follows you".
- **Remotes and logs:** sidebar items matching the name.
- **Commits by meaning:** up to 3 results as compact rows with a lane node, with a "Search commits for “…” ⌘↩" row.
- **Recent:** your last three searches, kept in memory for the session only.

↑/↓ move and ↩ opens. On a commit, ⌘↩ opens it in the replies pane, and ⇧↩ opens a person's profile in a new window. The footer shows the keys as `kbd` caps. With an empty query, it shows Recent, then the sidebar items.

### 9.17 Toasts

Toasts appear at the bottom center of the center column, 12pt above the bottom, on `popover` with `DS.Elevation.popover` and radius `lg`. Their text is in `monoCaption` (they speak git). They auto-dismiss after 4s; hovering pauses the timer. The delete toast is `rm a1f3c9e · Undo (⌘Z)`, and it stays for the whole undo window. Errors read `fatal: …` with a plain-sentence explanation after it.

### 9.18 Skeletons

Skeleton rows keep the rail running with a `rail` node and line, plus pulsing `SkeletonBar`s in the exact shape of a commit row: an avatar disc, a header bar at 40%, and two body bars at 90% and 60%. They're shown only while data is missing and never during a refetch, after `DS.Motion.skeletonDelay`.

### 9.19 Empty and error states

Reuse `EmptyState(fatal:message:)`: a mono `fatal:` line, one or two plain sentences, and at most one link button. Every destination defines both its empty state and its error state, and the copy stays dry and literal.

## 10. Menus and commands

Every action is reachable from the menu bar, with the shortcut shown.

| Menu | Items |
|---|---|
| **/dev/null** | About /dev/null · Check for Updates… · Settings… ⌘, · Services · Hide/Quit (system) |
| **File** | New Commit… ⌘N · New Remote… ⇧⌘N · New Org… ⌥⇧⌘N · Open in New Window ⌘O (the focused item) · Close ⌘W |
| **Edit** | System items · Find… ⌘F (filters the visible list: remotes, notifications) · Search… ⌘K |
| **View** | Show/Hide Sidebar ⌃⌘S · Show/Hide Replies Pane ⌥⌘0 · Following ⌘1 · Latest ⌘2 · Trending ⌘3 · Notifications ⌘4 · Remotes ⌘5 · Reload ⌘R · Enter Full Screen |
| **Go** | Back ⌘[ · Forward ⌘] · Previous Item ⌥↑ · Next Item ⌥↓ · Next Unread ⌃Tab · Your Profile ⇧⌘P · Starred ⇧⌘S · Scheduled ⇧⌘L · Jump to Newest ⌘↓ |
| **Commit** | Reply R · Quote… Q · Star S · Show Replies O · Open Commit Page ⇧⌘↩ · Copy Link Y · Give a Pastel · Translate · Pin to Profile · Report… · Delete… ⌘⌫ (own) |
| **Remote** | Show Info ⌘I · Pin · Mute ▸ · Stash ⌘E · Mark as Pulled ⇧⌘U · Block… (today's "Conversation" menu, renamed to the product's noun) |
| **Window** | System items · open windows listed by title |
| **Help** | Keyboard Shortcuts ? · /dev/null on the Web · What's New (opens the changelog) · Manage Devices… |

The single-letter commands (R, Q, S, O, Y) are shown in the menu but only fire when a commit list has keyboard focus, never inside a text field.

**Change from today.** ⌘N moves from New Remote to **New Commit**, because committing is the product's primary verb. New Remote moves to ⇧⌘N and New Org to ⌥⇧⌘N. The changelog for the release says so.

## 11. Settings window

The standard `Settings` scene, with a `TabView` of toolbar-style tabs. Each pane is a `Form(.grouped)`, 520pt wide.

| Tab (symbol) | Contents | API |
|---|---|---|
| General (`gear`) | Appearance (System / Light / Dark, local only); Open at Login; Timezone (picker, defaults to the Mac's); Translation language, Translate automatically | local; timezone and translation endpoints (new, §17) |
| Profile (`person`) | A read-only identity list (mono keys in a 6.5em column, `null` for missing values) with "Edit on GitHub" and "Sync from GitHub"; the Lane color picker (live preview: rail node, 48pt avatar with lane ring, lane-dotted handle; 7 swatches with "Auto" first) | `PUT me/github`, `PUT me/lane` |
| Pastéis (`gift`) | Pastéis mode on/off with the web's explanation | `PUT me/pasteis-mode` |
| Remotes (`bubble.left.and.bubble.right`) | Remotes on/off, who can push (People you follow / Everyone), requests, share pull receipts, Notifications, Sound. Today's SettingsView content goes here unchanged. | `PUT me/remotes`, `PUT me/remote-preferences` |
| Privacy (`hand.raised`) | Muted people and Blocked people lists with Unmute and Unblock; the note "Mutes and blocks follow your account everywhere." | `GET me/muted`, `GET me/blocked`, `DELETE users/…/mute`, `…/block` |
| Devices (`laptopcomputer`) | This Mac (current) and other devices, with Revoke | devices endpoints (new, §17) |
| Account (`person.crop.circle`) | Export your data (opens the web export, then shows "Your export downloads in the browser"); Sign Out; Delete account… (destructive, typed confirmation of your handle in the sheet) | web link; `DELETE me` |

## 12. Keyboard

The web's keymap is honored verbatim when a list has focus:

| Key | Action |
|---|---|
| `j` / `k` | Focus next / previous top-level commit (or notification, or remote in All Remotes) |
| `c` | Focus the staged composer |
| `r` | Reply to the focused commit: opens the replies pane with the composer focused |
| `q` | Quote the focused commit |
| `o` | Show or hide the replies of the focused commit in the replies pane |
| `s` | Star or unstar |
| `y` | Copy link |
| `K` | Open the focused author's preview |
| `Return` | Open the commit page |
| `g` then `l` / `e` / `p` / `s` | Following / Latest / Profile / Starred |
| `?` | The keyboard shortcuts sheet: bordered mono `kbd` caps in groups, as on the web |
| `Esc` | Close the replies pane, or clear the focus |

Focus is shown with a visible ring (`focusRing`) as well as the row state, and it survives polling. Every key has a menu equivalent (§10). Full Keyboard Access and VoiceOver rotor navigation work on every list.

## 13. Copy and vocabulary

- A post is a **commit**, a timeline is a **log**, and **star** is the verb. In the UI it's never "post", "tweet", "home", "feed", "like" or "bookmark". "Starred" is the saved list.
- Remotes keep their vocabulary: **remote**, **push**, **pulled**, **fetched** / **merged** / **dropped**, **stash** / **pop**, **org** of **maintainers** and **contributors**, **HEAD**.
- Buttons say exactly what happens: "Commit", "Schedule", "Reply", "Follow", "Push", "Delete…" (an ellipsis when a confirmation follows).
- Empty and error states speak git: a `fatal:` line, then a plain sentence. The wit lives in tone, never in a label someone needs to understand.
- "/dev/null" is always lowercase with both slashes. The bundle and file stay `DevNull`.

## 14. Accessibility

- Every icon button has an accessibility label, and counts are spoken exactly ("Notifications, 132 unread" even when the badge shows 99+).
- Commit rows are a single accessibility element whose label is "Maya Okafor, @maya, 4 minutes ago: body…" with custom actions (Reply, Star, Quote, Copy Link, Open Thread).
- Lane colors never carry meaning alone, because the author's name is always present.
- Respect Reduce Motion (no node pop, no rail draw, crossfades only), Increase Contrast (hairlines become `rail`, the sidebar loses vibrancy), and Dynamic Type sizes via the system text size setting.
- Hit targets are at least 24×24pt, and toolbar buttons are 28pt.
- Disabled, loading and enabled states of every button are the same size, and spinners go beside a stable label.

## 15. Privacy and data on the Mac

The rule from the web's data guidelines holds on the Mac: assume the disk has leaked.

- **Memory only:** commits, threads, notifications, profiles, messages, images, search results and recent searches. Drafts (`stash@{0}`) are kept for the running session only. They survive navigation and window closes, and are lost on quit. The UI says "Drafts stay until you quit /dev/null" in the composer's help.
- **Preferences** (`UserDefaults`): sidebar section expansion, the notification filter, the replies pane width, `HEAD@{last visit}` timestamps per log, appearance, and today's alert preferences. Nothing in them names or quotes another person.
- **Keychain:** the device key only, as today.
- **Banners** never contain message or commit text. Remote banners keep today's copy ("Maya Okafor sent a message"). Activity notifications do not banner; they badge the sidebar and the Dock only.
- **The Dock badge** is unread remotes plus unread notifications, capped at 99+.
- **Sign Out** clears memory, the drafts and the preferences that belong to the account.

## 16. Polling

There is no push service. When the app quits, all checks stop, and Settings → Remotes says so.

| What | Frontmost | Background (app inactive) |
|---|---|---|
| Open remote thread | 4s (today) | 60s (today) |
| Remotes list | today's cadence | today's cadence |
| Following, Latest | 30s | 5 min |
| Notifications count | 30s | 5 min |
| Scheduled | on open, then 60s while visible | — |

A failed poll keeps the last data and retries on the next tick. It shows `fatal: offline · retrying` in the sidebar footer, never an alert.

## 17. API map

| Surface | Endpoints (`/api/v1`, signed) |
|---|---|
| Logs | `GET log/{following\|latest\|trending}` |
| Commit, reply, quote, poll, images | `POST commits` (multipart), `POST commits/preview` |
| Thread, related | `GET commits/{id}`, `GET commits/{id}/replies`, `GET commits/{id}/related` |
| Star, pastel, vote, report, delete | `POST/DELETE commits/{id}/star`, `POST commits/{id}/pasteis`, `POST commits/{id}/poll/votes`, `POST commits/{id}/reports`, `DELETE commits/{id}` |
| Notifications | `GET notifications`, `GET notifications/{id}/group` |
| Profiles | `GET users/{handle}`, `GET users/{handle}/commits`, `/followers`, `/following`, `POST/DELETE …/follow`, `…/mute`, `…/block`, `POST …/dismiss` |
| Starred, suggestions | `GET starred`, `GET me/suggested-users` |
| Settings | `PUT me/lane`, `PUT me/pasteis-mode`, `PUT me/remotes`, `PUT me/remote-preferences`, `PUT me/github`, `GET me/muted`, `GET me/blocked`, `DELETE me` |
| Remotes | everything the app uses today |
| **To add to the signed API** (the web has them) | search users, search commits, scheduled commits (index, store, destroy, submission), commit pin, commit translation, mention and issue suggestions, timezone and translation preferences, devices (index, destroy) |

Data export stays on the web. The app opens `settings/export` in the browser.

## 18. Do and don't

**Do**

- Put every list of commits on the graph rail, the lower segment in the author's lane and the upper segment in the previous author's.
- Keep counts on logs quiet (muted mono). Badges are only for things addressed to you.
- Reuse today's Remotes views as they are; move them, don't redraw them.
- Give every action a menu item and a shortcut.
- Keep the layout still through polling, opening the replies pane and every action.
- Check every screen in light and dark, at 1440×900, at 1100×700, and at the 760pt minimum width.

**Don't**

- Don't use lane colors for text, buttons, badges or backgrounds; they mark people inside or beside the graph.
- Don't give blue to anything decorative or to a person.
- Don't wrap commits in cards or raise them with shadows.
- Don't add who-to-follow modules, trend panels or reaction pickers on commits. The only counts on a commit are stars, replies, quotes and pastéis.
- Don't badge the logs, show red dots, or banner activity.
- Don't store content on disk, put text in banners, or edit identity in the app.
- Don't render moderation or operations in the app.
