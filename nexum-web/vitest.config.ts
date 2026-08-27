import { defineConfig } from 'vitest/config'
import path from 'path'

export default defineConfig({
  test: {
    // Money-moving code: run serially so nothing races on shared globals
    // (we stub global fetch in the quote tests).
    fileParallelism: false,
    include: ['tests/**/*.test.ts'],
    environment: 'node',
  },
  resolve: {
    // Mirror tsconfig's "@/*" -> "./*" so tests import the same way the app does.
    alias: { '@': path.resolve(__dirname, '.') },
  },
})
