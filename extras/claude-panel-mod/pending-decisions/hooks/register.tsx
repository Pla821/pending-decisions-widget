import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'

import type { Pending } from '../types'

const PANE = 'pending-decisions'
// ⚠ 改成你自己的 pending.json 完整路徑（安裝後預設在 <使用者資料夾>/.claude/pending-decisions/data/pending.json）。
const FILE = 'C:/Users/YOUR_NAME/.claude/pending-decisions/data/pending.json'
// Change the tag when a Pending field changes.
const list = atom({ plugin: 'pending-decisions', key: 'list' } as const, [], {
  shape: 'pending-1',
})

async function load($: any): Promise<Pending[]> {
  try {
    const text = await $.fs.read(FILE)
    const items = JSON.parse(text).items ?? []
    return items
      .filter((i: any) => i.status === 'pending')
      .sort((a: any, b: any) => b.at - a.at)
      .map((i: any) => ({
        id: i.id,
        title: i.title || '(未命名對話)',
        at: i.at,
        question: (i.questions?.[0]?.question ?? '') as string,
      }))
  } catch {
    return []
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'pending',
      description: '開／關「待決定清單」側邊面板（列出還沒回答的選項框）',
    })
    void $.ui.open({ id: PANE, title: '待決定' })
    const refresh = async () => {
      const fresh = await load($)
      await update($, list, () => fresh)
    }
    await refresh()
    $.clock.every(5000, refresh)

    return next(e)
  })

  on('command.run', { command: 'pending' }, async $ => {
    await $.ui.open({ id: PANE, title: '待決定' })

    return { text: '待決定面板已打開（每 5 秒更新；完整一頁版是 data/pending.html）。' }
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text } = $.ui.resolve(e)
    const items = await read($, list)
    const room = Math.max(1, Math.floor(((e.viewport?.rows ?? 24) - 3) / 3))

    return (
      <Box flexDirection="column">
        <Text bold>待決定 {items.length} 件</Text>
        {items.length === 0 && <Text dimColor>目前沒有等你回答的選項框</Text>}
        {items.slice(0, room).map(it => (
          <Box flexDirection="column">
            <Text bold>{it.title}</Text>
            <Text>{it.question}</Text>
            <Text dimColor>{Math.max(1, Math.round((Date.now() - it.at) / 60000))} 分鐘前問的</Text>
          </Box>
        ))}
        {items.length > room && <Text dimColor>…還有 {items.length - room} 件，看一頁版</Text>}
      </Box>
    )
  })
}
