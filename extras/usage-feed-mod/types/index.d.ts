export type Weekly = { pct: number; resetsAt: string | null }

declare module 'claude-code' {
  interface PluginState {
    'usage-feed': { weekly: Weekly | null }
  }
}
