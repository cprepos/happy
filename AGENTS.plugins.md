# Agent Workflow: fork rules

These rules are for this fork (`cprepos/happy`). They add to `AGENTS.md`,
which is kept as upstream's text so upstream merges apply cleanly. Where this
file and `AGENTS.md` differ, this file wins.

## Releasing anything (additions to `AGENTS.md`'s section)

The native iOS app (`packages/happy-ios`, bundle `org.girthbass.native`) is
not an EAS app. Installing it on the user's iPhone or iPad, directly or over the
air, goes through `.agents/skills/happy-ios-ota/SKILL.md`.

In this fork `origin` is the upstream we merge from (see the next section), so
the `main` a release must match is **`fork/main`**: read `origin/main` as
`fork/main` wherever the release skill says it. The Expo preflight script that
used to enforce this went with the Expo app; nothing checks it for you now.

## Pushes Go To `fork`, Never `origin`

This repo has two push remotes:

- `fork` -> `git@github.com:cprepos/happy.git` -- **ours. Every push goes here.**
- `origin` -> `https://github.com/slopus/happy` -- the shared upstream we forked.
  **Never push to it**, on any branch.

`origin/main` advances on its own (in one recent window, 36 of 37 new commits
were a single upstream maintainer's), while our work sits on long-lived branches
that run hundreds of commits ahead of it. A push to `origin` therefore does not
"sync" anything -- it dumps unrelated app and CLI work onto a repo that is not
ours. Fetching `origin` is fine and often necessary; pushing is not.

`main` is our working line, and it is what the deploy checkout at
`/home/prep/happy` has checked out -- so `fork/main` is the target, and a push
there is one `git merge --ff-only` away from being deployable.

There is no `selfhost` branch any more. It and `main` had drifted into two
rebased copies of the same project -- 188 of one side's 223 commits had a
subject twin on the other -- which meant every change had to be landed twice
and each copy quietly missed things the other had (`selfhost` had no copy of
the ~190 happy-ios files behind the Mac app target; `main` had none of the
later voice work). They were merged on 2026-10-29 and `selfhost` was deleted.

One carve-out: inside GitHub Actions, `origin` is whatever repo the workflow is
running in, so `git push origin HEAD:main` in `.github/workflows/` is already
pushing to the fork. Leave it alone -- an Actions checkout has no `fork` remote,
so "correcting" it breaks CI. The rule above is about pushes from a developer or
agent working tree.

## Sync To Main (replaces `AGENTS.md`'s section)

This whole section replaces upstream's "Sync To Main" in `AGENTS.md`, whose
step 3 pushes to `origin`.

When the user says `sync to main` or `synt to main`, they mean:

1. Fetch the upstream (`git fetch origin main`) so you can see what has landed.
2. Rebase the current branch on `origin/main`.
3. Push the current HEAD to **`fork`** with a normal push:
   `git push fork HEAD:main`

Step 3 does **not** push to `origin`, which is the shared upstream -- see the
section above. Before pushing, show the commits the push contains, and confirm
the branch if it is anything other than `fork/main`.

Do not force push for this workflow.
