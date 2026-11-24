# Changelog

## Unreleased

## 0.1.1

- Opening a Working or Needs-you agent in Herdr no longer dismisses it; only Done agents
  are dismissed on opening.

## 0.1.0

First public version.

- Menu bar counts of working, needs-you and done agents; the idle count is optional.
- A menu of agents grouped by state, with keyboard navigation and a system-wide shortcut.
- Notifications as Herdbar banners or macOS notifications, with the session's title and
  the start of the agent's last message. Banners have a set position and duration; each
  kind of notification can play a sound.
- A click, or a second shortcut for the most recent notification, opens the agent's space
  and tab in Herdr.
- A rule for each agent: Default, Notify or Muted. Muted agents can be kept out of each
  part of the menu, and are then not counted in the menu bar.
- A row opens out to the agent's full status and last message.
- Agents can be dismissed to Idle until they next change: one at a time, all Done at once,
  on opening one in Herdr, or by a timer for Done agents. ⌘Z undoes the last dismissal.
- Launch at login.
