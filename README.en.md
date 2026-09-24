# Doyah Studio

[中文](README.md) · **English**

A **native database workbench for macOS** (Swift / SwiftUI — no JVM, no Electron): connect, write queries,
read results, move data — with a **real PTY terminal** and a **multi-language code editor** built in, and an
**AI agent** treated as a first-class capability.

What sets it apart from other clients is **not a stronger model, but being safe to use**: the agent is off by
default, every write is approved one at a time, and every outbound request lands in a single log you can read,
export or clear. **With no model endpoint configured, every other feature still works in full.**

- Product name **Doyah Studio**, bundle identifier `studio.doyah.DoyahStudio`
- Database support: **PostgreSQL** first-class. Multiple engines are the plan (dialects and drivers are
  pluggable); **GBase 8a** is the next target — its dialect and SQL generation layers exist, but there is
  **no instance to verify against**, so it is not claimed as supported.
- Requirements: macOS 14 or later
- **Bilingual UI**: English and 简体中文, switchable at runtime (no restart)

## What it does

- **Connect**: connection management, per-connection database switching; passwords live in the system Keychain
  and are never written into config files
- **Write and run SQL**: syntax highlighting, keyword completion, multiple statements per run, cancel anytime
- **Run only what you mean**: execute just the statement under the cursor, or just the selected fragment
- **Read results**: grid with per-column sorting, filtering, paging and copy
- **Export results**: CSV / JSON / table text / Markdown / replayable INSERT statements
- **Bottom terminal**: a real PTY shell (wide characters, ANSI palette, mouse reporting, DECCKM, right-click
  menu) — `vim`, `tmux` and `psql` all behave normally
- **Workspace**: pick a local directory as your workspace, lazy-loading file tree; click a text/code file to
  open it in the editor with **type-aware highlighting and completion** (JS / TS / SQL / HTML / CSS / JSON /
  Python …), save with ⌘S
- **Browse objects**: server → database → schema → table → column, expandable layer by layer, with an
  optional by-type grouped view
- **Understand structure**: ER diagram (plus Mermaid / DOT export), schema diff & sync, visual table structure
  editing (columns / indexes / constraints with a live DDL preview)
- **Diagnose**: execution plans, slow queries, database statistics, lock and blocking analysis, sessions and
  server-level objects (roles / tablespaces / extensions)
- **Move data in and out**: import Excel (.xlsx) / CSV (including GB18030) / TSV with column mapping and
  per-batch logs; export to Excel / CSV / JSON / Markdown / INSERT
- **Embedded browser**: browser tabs inside the editor area (loads no remote content by default), downloads go
  to an authorized directory, and every outbound request is recorded
- **Manage databases**: create, alter properties, drop (typing the database name is required to confirm)
- **Privileges**: inspect account privileges, and see the exact statements before granting or revoking
- **Lock analysis**: who waits for whom, for how long, down to the blocking session
- **Dangerous-statement guards**: unconditional bulk UPDATE / DELETE, DROP TABLE and friends ask for
  confirmation first (can be turned off)
- **AI agent (off by default)**: natural language → SQL, spec → data task, task scheduling and scoped export;
  output only ever lands in the editor or the approval queue — **never auto-executed**, each run approved
  separately, with a full audit trail (time / connection / statement / model / duration / outcome, exportable
  and free of secrets). With the master switch off, the app makes no network calls at all
- **Keyboard shortcuts** everywhere: every toolbar and menu action has one; click “?” in the toolbar for the
  full table

A fuller list (including what is **not** done yet) lives in
[功能清单（一页纸）](Docs/功能清单（一页纸）.md) and [功能清单（管理视图）](Docs/功能清单（管理视图）.md)
(both in Chinese).

## Where the project stands (stated plainly)

- **PostgreSQL is first-class** (verified on 16.2 and 18.6). The dialect and SQL generation layers for GBase 8a
  and MySQL exist, but there is **no instance to verify against**, so they are not listed as supported.
- **Scope**: 223 requirements (168 FR · 43 NFR · 12 AC); current FR status **113 ✅ / 49 🟡 / 6 ⬜**
  (🟡 = implemented but awaiting manual acceptance, or blocked on an external environment). Statuses are
  derived from the index in `Docs/需求规范书.md` §10.1 and checked by `Scripts/check-doc-tables.py` on every
  run — they are never hand-maintained.
- **Agent**: off by default; bring your own OpenAI-compatible endpoint (a local endpoint is preferred and may
  be key-less). Without one, everything except the agent is available.
- **Platforms**: macOS 14+ (this repository). The Linux client is **the same product, a second implementation**:
  the contract layer is specified, the implementation is still to be built.
- **Known gaps**: SSH tunneling (FR-CONN-18), GBase / MySQL drivers, line numbers in the editor, and a few
  agent items that need a model endpoint.
- **Sandboxed builds**: under the App Store sandbox child processes are restricted (`pg_dump` / `ssh` / `^C`
  are unreliable). For the full feature set build with `DOYAH_NO_SANDBOX=1 ./Scripts/build-app.sh`.

## Internationalization

Bilingual support is built in from the start rather than retrofitted:

- **1388 UI strings** live in one table with both English and 简体中文, and the language can be **switched at
  runtime without restarting** the app (the UI rebuilds in place; open tabs and content are preserved).
- **Nothing can silently skip translation**: unit tests assert that every key has both languages, no string is
  empty, the English text carries no Chinese residue, the Chinese text is not left in English, and format
  specifiers match between languages. A ratchet gate in `Scripts/verify-all.sh` additionally stops new
  user-facing text from appearing in `Core` outside that table.
- Menus, diagnostics, terminal messages and the workspace editor follow the same table; the repository's
  top-level README is bilingual too ([中文](README.md) / English).
- **The three engineering documents and design notes are Chinese-only for now.** The priority is
  internationalizing the *product*; document translations will come when there are real international
  collaborators (translations of living documents go stale, and a stale translation misleads more than none).

## Build and run

Xcode (with the macOS 14 SDK) is required. You do not need the Xcode GUI:

```bash
# Build and run the Core unit tests (no database needed)
./Scripts/verify-core.sh

# Build and assemble the .app (ad-hoc signed, runs locally)
./Scripts/build-app.sh
open dist/DoyahStudio.app
```

## Repository layout (short version)

```
Core/       Core logic: connections, execution, dialects, metadata, results, agent capabilities
App/        SwiftUI interface
CLI/        Command-line version (real connections and query execution)
Tests/      Unit tests
Scripts/    Build and verification scripts
Docs/       Product documentation
Vendor/     Third-party dependency (PostgresNIO, the PostgreSQL driver)
```

## Documentation

Product documentation lives in [Docs/](Docs/) (see the [documentation index](Docs/README.md)). Public parts:

- [Product capability plan](Docs/产品能力规划说明书.md) — why, what, and in which order
- [Requirements specification](Docs/需求规范书.md) — every requirement, its acceptance criteria and status
- [High-level design](Docs/概要设计.md) — contracts, layering, ADRs (dual-platform)
- [Feature list, one page](Docs/功能清单（一页纸）.md) and [management view](Docs/功能清单（管理视图）.md)
- Design notes under [Docs/design/](Docs/design/)

Still kept locally and not published: the two research reports, the compatibility matrix, test cases, the
release plan and the manual acceptance runbook (they contain machine-specific environments and steps).

## License

Released under the [Apache License 2.0](LICENSE).

Third-party components and their licenses are listed in
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) (also shipped inside the `.app` under
`Contents/Resources/`).
