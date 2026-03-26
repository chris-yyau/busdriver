export default {
  extends: ['@commitlint/config-conventional'],
  rules: {
    'body-max-line-length': [0, 'always'],
  },
  ignores: [
    (message) => /^(chore|build)\(deps(-dev)?\):/i.test(message),
  ],
};
