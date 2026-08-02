# Contributing

Contributions are welcome — bug reports, fixes, features, docs. This file is the whole
process; there is nothing else to sign or join.

## Getting set up

```sh
git clone https://github.com/felipeva/codereview-annotator.nvim
cd codereview-annotator.nvim
make hooks   # once per clone: enables the commit-msg hook (git does not version hooks)
make deps    # clones plenary into .tests/
make all     # lint + the full suite, ~5s
```

You need Neovim **0.12+**, `git`, and [`stylua`](https://github.com/JohnnyMorganz/StyLua)
for linting. Nothing else — the test suite deliberately depends on plenary alone.

To run the plugin from your checkout, point your plugin manager at the directory:

```lua
{ dir = "~/path/to/codereview-annotator.nvim", cmd = "CodeReview", opts = {} }
```

## Before you write code

**Open an issue first** for anything with a design decision behind it. The
[Design notes](README.md#design-notes) section of the README exists because several
obvious-looking approaches here are wrong for non-obvious reasons — a short conversation
on an issue is cheaper than a rewritten PR.

Typo fixes, doc corrections and obviously-correct one-line bug fixes can go straight to a
PR.

## Tests

`make all` before every commit that touches `lua/`. It takes about five seconds.

```sh
make test                                            # the whole suite
make test-file FILE=tests/codereview/diff_spec.lua   # one spec, in-process
make lint                                            # stylua --check
make format                                          # stylua, in place
make perf                                            # open-time report, not part of CI
```

New behaviour needs a spec. [`tests/README.md`](tests/README.md) covers the layout, the
fixture scripts, what is deliberately not covered, and the traps worth knowing before you
change a fixture — read it before adding one. The short version:

- Each spec file gets its own Neovim and builds its own throwaway git fixture.
- Use `make test-file`, never `:PlenaryBustedFile` — that command spawns a child without
  `-u` and loads your real config instead of `tests/minimal_init.lua`.
- Fixtures are Lua and Markdown on purpose: Neovim core ships those parsers and their
  `highlights` queries, so CI needs no nvim-treesitter and no compiler.

CI runs the suite on Neovim stable and nightly, plus `stylua --check`.

## Commits

**Conventional Commits**, validated by `.githooks/commit-msg` (installed by `make hooks`).

```
<type>(<optional scope>)!: <description>
```

- types: `build` `chore` `ci` `docs` `feat` `fix` `perf` `refactor` `revert` `style` `test`
- description: lowercase imperative, no trailing period
- subject at most 72 characters, blank line before the body
- the body explains **why** — the diff already says what

Branch off the issue: `<type>/<issue>-<slug>`, e.g. `feat/12-single-annotation-queue`. The
`<type>` is the same Conventional Commits type the work will land under, so the branch, the
commits and the PR title all agree.

## Pull requests

- The title is a Conventional Commits subject — it becomes the squash commit.
- The body closes the issue (`Closes #12`) and says why, not what.
- Keep it to one vertical slice. Two unrelated changes are two PRs.
- Update `README.md` and `doc/codereview.txt` when you change user-facing behaviour; both
  are hand-written and neither is generated from the other.

## Code style

`stylua.toml` is the whole style guide — `make format` settles every formatting question.
It sets `syntax = "Lua52"`, which is what allows `goto`/`::label::`.

Beyond formatting, the two things worth matching:

- **Comments explain why.** The codebase is dense with rationale comments on the parts that
  look wrong until you know the constraint. Keep that ratio; do not narrate what the line
  does.
- **`require("codereview").annotate(type)` is the public capture seam.** Extend it rather
  than adding a parallel entry point, so a keybinding never has to reach into an internal
  module.

## Built with Claude Code

This plugin was written with [Claude Code](https://claude.com/claude-code), and the repo is
set up to keep working that way. That is stated plainly for two reasons: so you know what
you are reading, and so you know agent-assisted contributions are welcome here rather than
merely tolerated.

What is in the repo for that:

| File | What it does |
| --- | --- |
| [`CLAUDE.md`](CLAUDE.md) | Operating instructions an agent reads on entering the repo — the workflow above, in imperative form |
| [`docs/agents/`](docs/agents/) | Where issues live, the triage label vocabulary, and the domain-doc layout |
| [`README.md`](README.md#design-notes) § Design notes | Every non-obvious constraint that cost real debugging time |
| [`tests/README.md`](tests/README.md) | The suite's layout, and the fixture traps that will otherwise cost an afternoon |

Point your agent at `CLAUDE.md` and it will follow the same branch, commit and PR
conventions this file describes.

**The bar is identical either way.** However a change was produced, you are the author of
what you open: the tests pass, the design notes were read, the rationale in the PR body is
yours, and you can answer questions about it in review. A PR that reads as an unreviewed
model dump — invented APIs, tests that assert nothing, a diff twice the size of the
problem — gets sent back regardless of who or what typed it. There is no requirement to
disclose tool use, and no penalty for it.

## Reporting bugs

Use the issue template. The parts that actually determine whether a bug is reproducible:
`nvim --version`, your `opts` table, the repository shape (branch scope? untracked files? a
rename?), and what you expected instead. A minimal fixture beats a description.

## Security

See [`SECURITY.md`](SECURITY.md).

## License

By contributing you agree that your contributions are licensed under the
[MIT License](LICENSE), the same terms that cover the project.
