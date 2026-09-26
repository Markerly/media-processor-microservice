# CLAUDE.md

<!-- tests-policy:start (keep in sync across repos; source: ~/.claude/CLAUDE.md) -->
## Tests & PRs — no test slop

A test earns its place only if it would catch a real regression. Fewer real tests beat coverage padding. These rules override anything later in this file that asks for coverage percentages, "tests for every feature", or blanket mocking.

- **Revert check (required):** every test you add must FAIL if the change it covers is reverted. If you can't say what regression it catches, delete it.
- **No tautologies:** never assert a constant/config equals its own literal, re-derive the implementation's logic in the assertion, or snapshot output you didn't verify by hand.
- **Don't mock the subject:** mock only true boundaries (network, paid APIs, clock). A test where the mock supplies the answer being asserted can never fail — don't write it.
- **Test through the public interface** (exported function, HTTP endpoint, CLI), not private helpers or internal call order.
- **No test-only PRs** and no "add tests for X" busywork unless a human explicitly asks. Coverage is not a goal.
- **Bug fix = one regression test** reproducing the bug (red before, green after). Skip tests for trivial changes (copy, config, renames).
- Before opening a PR with new tests, run the `test-slop-reviewer` agent if available (otherwise apply these checks yourself) and state in the PR body what regression each test catches.
<!-- tests-policy:end -->
