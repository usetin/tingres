# Agent instructions

tingres is PostgreSQL written in Tin. Read [ARCHITECTURE.md](ARCHITECTURE.md) (layers, package contracts) and
[ROADMAP.md](ROADMAP.md) (milestones) first, then the Tin primer in the Tin checkout:
`$TIN_ROOT/toolchain/docs/AGENT_PRIMER.md` (language), `LANGUAGE.md`, `STDLIB.md`, `ERRORS.md` beside it. Edition 1 syntax only.

- Build and test with `$TIN` (default `~/dev/extra/tin/tin`): `tin check FILE.tin`, `tin build main.tin -o bin/NAME/tingres`,
  `tin test DIR`. Never modify the Tin checkout; a compiler bug gets a minimal repro under `tests/compiler_bugs/` and a line in `BUGS.md`.
- Each agent owns the packages the lead assigned and edits only those (plus its own tests). The contracts in
  ARCHITECTURE.md section 2 are the only coupling: if you need a change, edit that section in a separate small
  commit and say so in your report; do not reach into another package's files.
- Each agent builds into its own dir `bin/<agent>/` and never runs long servers in the foreground.
- Commit small and often on your own branch `agent/<name>`; do not push to `main`, do not rebase others' work.
- Never weaken, skip or delete a test to get green. An unsupported feature returns a PostgreSQL error (`0A000`).
- Performance work is judged on Linux against real PostgreSQL only; never quote macOS numbers.
- Differential truth is a real PostgreSQL 17 (`/opt/homebrew/bin/postgres`, `psql`): run a scratch instance on a free port with a private data dir.
