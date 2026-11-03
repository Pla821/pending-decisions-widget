export type Weekly = { pct: number; resetsAt: string | null; approx?: boolean }

declare module 'claude-code' {
  interface PluginState {
    'usage-feed': { weekly: Weekly | null }
  }
}
