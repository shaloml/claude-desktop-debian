---
name: publish-desktop
description: Check upstream for a newer official Claude Desktop, build it with build.sh, then stop, uninstall, and replace the copy installed on this machine. Use when the user wants to update or reinstall their local Claude Desktop from source.
---

Replace the Claude Desktop installed on this machine with a fresh build of the
newest official upstream release.

```bash
bash "$CLAUDE_PROJECT_DIR/.claude/skills/publish-desktop/publish-desktop.sh"
```

## What it does

| Step | Action |
|------|--------|
| 1 | Resolve the newest official `.deb` from Anthropic's APT index (via the repo's own `resolve_official_deb`) and compare it to the installed version. **Nothing newer → report and exit 0.** |
| 2 | Download that `.deb` into `~/.cache/claude-desktop-debian/official/` and verify its SHA-256 against the index. |
| 3 | Build our package: `./build.sh --build deb --clean yes --deb <downloaded>`. |
| 4 | Stop every running Claude Desktop process (SIGTERM, then SIGKILL after 15s). |
| 5 | `sudo apt-get remove -y` the installed package. |
| 6 | `sudo apt-get install -y` the freshly built `.deb`, then verify it registered with dpkg. |
| 7 | Fast-forward **our fork**'s default branch to upstream's, so the fork carries the `OFFICIAL_DEB_*` pins for the release just installed. |

## Your Task

1. **Run the script** (background it — the build takes a few minutes).
2. **Watch for the password dialog.** Steps 5 and 6 need root. An agent session
   has no terminal, so `sudo` cannot prompt on stdin; the script falls back to
   `sudo -A` with a graphical askpass helper, which opens a password dialog **on
   the user's desktop**. Tell the user to look for it — the run blocks until
   they answer. It authenticates up front, before anything is killed or removed.
3. **Report honestly.** If it exits with "No new version", say exactly that — do
   not build or reinstall anyway unless the user asks for `--force`.

Do not try to feed `sudo` a password, and do not ask the user for one. If no
askpass helper exists and there is no display, the script says so and tells the
user to run it from a real terminal; relay that rather than working around it.

## Options

| Flag | Effect |
|------|--------|
| `--force` | Rebuild and reinstall even when the installed version is already current. |
| `--skip-build` | Reuse the `.deb` already sitting in the project root. |
| `--no-fork-sync` | Skip step 7 entirely. |
| `--fork-remote NAME` | Git remote of our fork. Default `fork`, or `$CLAUDE_FORK_REMOTE`. |
| `--dry-run` | Print every step, change nothing. Good for showing the user the plan. |

## Notes

- **The fork sync only ever pushes to a fork, and never with `--force`.** This
  clone carries a remote for the project we forked (`origin` →
  `aaddrick/claude-desktop-debian`); a publish script that pushed there would
  rewrite someone else's repository. So step 7 refuses to run unless the target
  remote (a) is not `origin`, (b) does not resolve to the same `owner/repo` as
  `origin` under a different remote name, and (c) reports `isFork: true` to `gh`.
  A rejected push means our fork's branch has commits upstream lacks — that is a
  human's call to reconcile, so the script reports it and stops rather than
  force-pushing. Step 7 is non-fatal: the package is already installed by then.
- **The repo stays clean.** `build.sh` always builds from the `OFFICIAL_DEB_*`
  pins in `scripts/setup/official-deb.sh`, which lag upstream until CI's
  `check-claude-version` bumps them. Rather than edit that tracked file, this
  skill downloads the newest official `.deb` itself and feeds it to
  `build.sh --deb`. Expect a pin-mismatch warning from `build.sh` — that is the
  intended path, not a failure.
- **The package was renamed.** Our package is `claude-desktop-unofficial`; the
  legacy one (and Anthropic's own) is `claude-desktop`. The script detects
  whichever is installed and removes that one.
- **User data survives.** `~/.config/Claude` is not owned by dpkg. The script
  uses `remove`, never `purge`.
- **Process matching is by `/proc/PID/exe`, not `pgrep -f`.** A `pgrep -f
  claude-desktop` also matches the script's own command line and any shell
  holding that string — including the Claude Code session running this skill.
  See `docs/learnings/quit-cleanup-scope-fence.md`.

## Optional Guidance

$ARGUMENTS
