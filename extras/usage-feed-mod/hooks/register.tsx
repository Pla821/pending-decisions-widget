import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'

import type { Weekly } from '../types'

const weekly = atom({ plugin: 'usage-feed', key: 'weekly' } as const, null)

// Claude pushes the plan's rate-limit windows here whenever one moves a whole point.
// Show the weekly one above the prompt, and write it where the desktop widget reads it
// (<home>/.claude/pending-decisions/data/usage.json, same shape the widget's own feeds use).
export const register: Register = on => {
  on('session.measure', async ($, e, next) => {
    const win = e.rateLimits.find(l => l.kind === 'seven_day')

    if (win) {
      const next_: Weekly = { pct: win.percentUsed, resetsAt: win.resetsAt ?? null }
      await update($, weekly, () => next_)

      const home = await $.env.get('USERPROFILE')
      // only feed the widget where it is installed; never create its folders
      if (home && (await $.fs.exists(`${home}/.claude/pending-decisions/data`))) {
        const resets = win.resetsAt ? Date.parse(win.resetsAt) / 1000 : null
        const body = JSON.stringify({
          at: await $.clock.now(),
          source: 'mod',
          five_hour: null,
          seven_day: { pct: win.percentUsed, resets_at: resets },
        })
        try {
          await $.fs.write(`${home}/.claude/pending-decisions/data/usage.json`, body)
        } catch {
          // the widget is not installed here: nothing to feed
        }
      }
    }

    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const w = await read($, weekly)
    if (e.props.hasSurvey || w === null) {
      return next(e)
    }

    const { Box, Text } = $.ui.resolve(e)

    return (
      <Box>
        <Text dimColor>Weekly usage {Math.round(w.pct)}%</Text>
      </Box>
    )
  })
}
