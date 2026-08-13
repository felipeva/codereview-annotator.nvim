# Security Policy

## Supported versions

This project has no release branches. Fixes land on `master`; update to the latest commit.

## Reporting a vulnerability

Report privately — **do not open a public issue**.

- Preferred: [open a draft security advisory](https://github.com/felipeva/codereview-annotator.nvim/security/advisories/new)
- Or email **jfelipevalr@gmail.com**

Include what an attacker can do, the repository or configuration shape needed to reach it,
and a reproduction if you have one. Expect an acknowledgment within a week.

## What is in scope

The plugin runs `git` subprocesses over the repository you open it in, reads and writes
state under `stdpath("state")/codereview/`, and renders untrusted repository content into a
Neovim buffer. Things worth reporting:

- A repository whose contents (branch names, paths, diff bodies, file content) can cause
  command injection, path traversal outside the repository root, or an unexpected write.
- Persisted state under `stdpath("state")` that can be crafted to execute code or escape
  its directory when loaded.
- A crafted diff that makes the renderer or the treesitter replay execute repository
  content rather than display it.

## What is out of scope

- The behavior of any `send`, `pick_target` or `compose` adapter you supply. The plugin
  hands the rendered payload to your function and has no opinion about where it goes;
  what that function does with it is yours to secure.
- The plugin makes no network requests of its own, and reads no credentials.
