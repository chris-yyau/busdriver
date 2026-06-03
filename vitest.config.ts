import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    // Scoped to __tests__/ ONLY. The repo embeds illustrative *.test.ts snippets
    // inside skills/ markdown and example dirs — an unscoped glob would collect them.
    include: ['__tests__/**/*.test.ts'],
    coverage: {
      provider: 'v8',
      reporter: ['text', 'lcov'], // lcov for Codecov compatibility
      // The JS surface under test lives in scripts/. node_modules and skill
      // example code are never the subject of these tests.
      include: ['scripts/**/*.js'],
      exclude: ['node_modules/', 'skills/', 'dist/', '**/*.config.*'],
    },
  },
})
