# Agent Workflow

## Releasing anything

Every release goes through the `release` skill: `.agents/skills/release/SKILL.md`.
Read it in full before running `eas update`, `eas build`, `eas submit`, any
`pnpm ota*` or `pnpm release:*` script, or dispatching a release workflow.
That covers preview and production OTA updates, native builds, store
submissions, and CLI publishes.

The rule the skill opens with is the one that is never skipped: **release from
a local `main` that is exactly `origin/main`, checked against a fetch made right
then, with a clean tree.** Not from a worktree. Not from a branch. Not from a
`main` that is ahead or behind. The mobile release scripts refuse anything else
(`packages/happy-app/sources/scripts/releasePreflight.mjs`).

The only exception is one the user asks for by name in the current
conversation. A standing instruction from an earlier session is not that, and
neither is your own judgement that it is probably fine. When they do ask, the
skill says how: show what `main` commits the release will lack, get a yes, run
with `HAPPY_RELEASE_ALLOW_OFF_MAIN=1`, and say it was off-main in the report.

Why: an OTA channel serves whatever was published last, not whatever is on
`main`. On 2026-09-20 a preview OTA from a stale worktree silently rolled four
shipped fixes off every preview phone for hours. Git looked fine the whole time.

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

## Sync To Main

When the user says `sync to main` or `synt to main`, they mean:

1. Fetch the upstream (`git fetch origin main`) so you can see what has landed.
2. Rebase the current branch on `origin/main`.
3. Push the current HEAD to **`fork`** with a normal push:
   `git push fork HEAD:main`

Step 3 does **not** push to `origin`, which is the shared upstream -- see the
section above. Before pushing, show the commits the push contains, and confirm
the branch if it is anything other than `fork/main`.

Do not force push for this workflow.
