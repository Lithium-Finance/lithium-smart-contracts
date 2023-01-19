module.exports = {
  extends: ['prettier', 'airbnb-base'],
  plugins: ['import', 'jest', 'jsdoc'],
  rules: {
    'import/no-extraneous-dependencies': 'off',
    'no-await-in-loop': 'off',
    'no-console': 'off',
    'no-return-await': 'off',
    'no-unused-expressions': 'off',
    'operator-linebreak': [
      'error',
      'after',
      {
        overrides: {
          '?': 'before',
          ':': 'before',
          '&&': 'before',
          '||': 'before',
          '=': 'none',
        },
      },
    ],
  },
  env: {
    'jest/globals': true,
  },
  parserOptions: {
    ecmaVersion: 2020,
  },
};
