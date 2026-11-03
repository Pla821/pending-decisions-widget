# usage-feed (mod)

A Claude Code mod for the pending-decisions widget. It shows **Weekly usage N%** above the prompt and writes the same number to
`%USERPROFILE%\.claude\pending-decisions\data\usage.json` (only if the widget's `data` folder exists), so the widget's "週 N%" pill is live
without reading any login file or spending quota.

Install (type at the prompt of a terminal Claude Code session; answer `y` to add the marketplace, then pick a scope):

```
/plugin install usage-feed --marketplace Pla821/pending-decisions-widget
```

Needs a Claude Code build that supports mods (hooks `modules`). It only updates while a session that has the mod loaded is open.
