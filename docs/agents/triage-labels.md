# Triage Labels

The skills speak in terms of five canonical triage roles. This file maps those roles to the actual label strings used in this repo's issue tracker.

This repo uses the canonical strings unmodified — no overrides.

| Label in mattpocock/skills | Label in our tracker | Meaning                                  |
| -------------------------- | -------------------- | ---------------------------------------- |
| `needs-triage`             | `needs-triage`       | Maintainer needs to evaluate this issue  |
| `needs-info`               | `needs-info`         | Waiting on reporter for more information |
| `ready-for-agent`          | `ready-for-agent`    | Fully specified, ready for an AFK agent  |
| `ready-for-human`          | `ready-for-human`    | Requires human implementation            |
| `wontfix`                  | `wontfix`            | Will not be actioned                     |

When a skill mentions a role (e.g. "apply the AFK-ready triage label"), use the corresponding label string from this table.

## Which of these exist on the repo

`wontfix` (from GitHub's default set), `ready-for-agent` and `needs-triage` exist.
`needs-info` and `ready-for-human` have not been created yet.

`gh issue edit --add-label` errors on an unknown label rather than creating it — so before
first applying one of the missing two, create it:

```sh
gh label create needs-info      --description "Waiting on reporter for more information"
gh label create ready-for-human --description "Requires human implementation"
```

Edit the right-hand column of the table above to match whatever vocabulary you actually use.
