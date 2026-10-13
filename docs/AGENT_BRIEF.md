# Common brief for every tingres agent

tingres is PostgreSQL written entirely in Tin (https://github.com/usetin/tingres, checkout /Users/mhomsi/dev/extra/tingres).
It must match PostgreSQL's observable behaviour and be MUCH FASTER than real PostgreSQL. About twenty agents work at once; each
owns different files. `origin/main` is the integration line.

## Read first
AGENTS.md, ARCHITECTURE.md (section 2 = package contracts, section 4 = performance rules), README.md (generated stats), BUGS.md.
Tin is a new strict language (edition 1): read `/Users/mhomsi/dev/extra/tin/toolchain/docs/AGENT_PRIMER.md` FIRST, then LANGUAGE.md,
STDLIB.md, ERRORS.md there. Parameters that are modified must be declared `mut`; there is no Go syntax. When the compiler rejects
something, read ERRORS.md instead of guessing. Build/test with `/Users/mhomsi/dev/extra/tin/tin`: `tin check FILE`, `tin test DIR`,
`tin test -bench DIR`, `tin build FILE -o OUT`, `tin fmt -w FILE`.

## Your worktree (never work in the main checkout)
```sh
git -C /Users/mhomsi/dev/extra/tingres fetch origin
git -C /Users/mhomsi/dev/extra/tingres worktree add /Users/mhomsi/dev/extra/tingres-wt/<name> -b agent/<name> origin/main
```
`<name>` is given in your task. Own ONLY the files/directories your task names; never edit other agents' files. If you need a change in
someone else's area add `NEEDS-OTHER: <package>: <what>` to BUGS.md. If you need something missing or broken in Tin itself (std function,
runtime primitive, compiler bug), NEVER edit /Users/mhomsi/dev/extra/tin: add `NEEDS-TIN: <what, minimal repro or API sketch, blocked file>`
to BUGS.md and push it (the lead opens the Tin PRs); work around it meanwhile.

## Push protocol
Atomic commits (one logical change each, descriptive message). After each step:
`git fetch origin && git merge --no-edit origin/main`, run your tests (`tin test <dir>` must END with a `PASS: N tests` line, no panic, no
FAIL), then `git push origin HEAD:main` (retry on rejection; never force-push; never push a state where your packages do not compile or
their tests fail). Commit identity: `git -c user.name="Mohamad Homsi" -c user.email=mohamad.homsi@anghami.com commit`.

## Ground truth and tests
Real PostgreSQL 17 is installed (/opt/homebrew/bin: initdb, postgres, psql). Run a scratch instance on a free port with a private data
directory under $TMPDIR, and ALWAYS stop it and delete the directory when you finish or give up (no stray processes: the lead found many).
Checked-in golden files plus a generator script (pattern: types/testdata/gen_types_golden.sh) so `tin test` never needs PostgreSQL.
The PostgreSQL 17 regression suite is checked out (read-only data) at /Users/mhomsi/dev/extra/tingres-pgsrc/pg/src/test/regress.
Never weaken, skip or delete a test to get green. Long commands (benchmarks, servers, test suites) run in the background with timeouts.

## Performance
Speed claims need Linux numbers (tingres vs real PostgreSQL, same machine, interleaved, medians, ratio). macOS numbers are only a
development guide and are never quoted as results. Hot paths: no per-row allocation, write into caller buffers, no comparator
indirection, benchmark everything you write that is on a hot path (`tin test -bench`).

## Finishing
Do not stop between steps and do not report a first slice as done. Report only when the whole task is done or you are genuinely blocked
(say exactly on what). The report includes the literal final PASS line of your test run, the public API you ended up with, and known gaps.
