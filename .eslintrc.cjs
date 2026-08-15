module.exports = {
    env: {
        es2022: true,
        jest: true,
        node: true,
    },
    extends: ['eslint:recommended'],
    parserOptions: {
        ecmaVersion: 2022,
        sourceType: 'commonjs',
    },
    rules: {
        'no-unused-vars': ['error', { argsIgnorePattern: '^_' }],
    },
};
