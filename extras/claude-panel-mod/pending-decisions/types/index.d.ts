export type Pending = { id: string; title: string; at: number; question: string }

declare module 'claude-code' {
  interface PluginState {
    'pending-decisions': { list: Shaped<Pending[]> }
  }
}
