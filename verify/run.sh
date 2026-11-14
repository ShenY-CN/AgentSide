#!/usr/bin/env bash
# End-to-end checks for the agent-sidebar Tern plugin (window half only).
#
# The harness boots an ISOLATED Tern: its own TERN_CONFIG_DIR, session-daemon
# socket and control endpoint under a temp dir, so the sessions, settings and
# plugins of the Tern you are running are untouched. The window, its daemon and
# the temp dir all go away when this script exits, however it exits.
#
# usage:  bash verify/run.sh [PLUGIN_DIR]     (default: this package's root)
#
# Environment:
#   TERN_BIN           the Tern executable
#                      (default /Applications/Tern.app/Contents/MacOS/tern)
#   VERIFY_AGENT_TURN  set to 1 to let the `done` check drive a real agent turn
#                      (it spends one turn of the installed agent's account)
#
# Tern verbs used, each confirmed with `tern COMMAND --help` / `tern help dev`
# before it was written here; the exact invocation sits beside its check:
#   tern plugin link DIR
#   tern plugin list
#   tern ls --json
#   tern new session NAME
#   tern new tab [SESSION] [LAUNCH]
#   tern close BLOCK
#   tern focus BLOCK
#   tern send BLOCK text TEXT | keys COMBO
#   tern run BLOCK COMMAND...
#   tern ctl --control EP COMMAND...
#   tern ctl --control EP --file SCENARIO
#   tern --control EP            (opens a window on that endpoint; `tern help dev`)
#
# Scenario files live beside this script (verify/scenarios/): the plugin's own
# chord, the palette, and a click on an agent row.

set -u

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd -- "$HERE/.." && pwd)
PLUGIN_DIR=${1:-$REPO}

BIN=${TERN_BIN:-/Applications/Tern.app/Contents/MacOS/tern}
# The documented log path (Settings > Advanced > Open logs). Tern keeps one log
# per user, so every line is tagged with its process id: this run reads only
# what its own processes appended from LOG_START on.
LOG_HOME="$HOME/Library/Logs/Tern/tern.log"
# The coding agents the plugin reports; `appear`/`state`/`done`/`group` need one
# of these installed. `cli` needs one Tern leaves in a pane, so it uses any of
# them but omp (Tern adopts a pane running omp as an agent block).
AGENT_SET="omp claude codex opencode gemini aider amp cursor-agent crush goose hermes kimi"

pass=0
fail=0
skip=0
ok() { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s: %s\n' "$1" "$2"; }
skp() { skip=$((skip + 1)); printf 'SKIP %s: %s\n' "$1" "$2"; }

# --- preflight -------------------------------------------------------------

if [ ! -d "$PLUGIN_DIR" ]; then
	printf 'FAIL setup: no plugin directory at %s\n' "$PLUGIN_DIR" >&2
	exit 2
fi
if [ ! -x "$BIN" ]; then
	printf 'FAIL setup: no Tern executable at %s (set TERN_BIN)\n' "$BIN" >&2
	exit 2
fi
if [ "$(uname -s)" != Darwin ]; then
	printf 'FAIL setup: this harness drives the Tern macOS build\n' >&2
	exit 2
fi

# --- isolated instance -----------------------------------------------------

BASE=${TMPDIR:-/tmp}
BASE=${BASE%/}
D=$(mktemp -d "$BASE/agent-sidebar-verify.XXXXXX") || exit 2
mkdir -p "$D/config" "$D/work"
export TERN_CONFIG_DIR="$D/config"
export TERN_DAEMON_SOCKET="$D/daemon.sock"
CTL="$D/ctl.sock"

LOG="$LOG_HOME"
if [ -d "$TERN_CONFIG_DIR/logs" ]; then LOG="$TERN_CONFIG_DIR/logs/tern.log"; fi
LOG_START=1
if [ -f "$LOG" ]; then LOG_START=$(( $(wc -l < "$LOG" | tr -d ' ') + 1 )); fi

WPID=""
WINDOW_PIDS=""

cleanup() {
	local code=$?
	trap - EXIT INT TERM HUP
	if [ -n "$WPID" ] && kill -0 "$WPID" 2>/dev/null; then
		"$BIN" ctl --control "$CTL" quit >/dev/null 2>&1 || true
		local n=0
		while [ "$n" -lt 25 ]; do
			kill -0 "$WPID" 2>/dev/null || break
			sleep 0.2
			n=$((n + 1))
		done
		kill "$WPID" 2>/dev/null || true
		wait "$WPID" 2>/dev/null || true
	fi
	# A window killed outright can leave its session daemon behind: end it by
	# the socket it listens on, so nothing of this run survives.
	local dp
	dp=$(lsof -t -- "$TERN_DAEMON_SOCKET" 2>/dev/null | tr '\n' ' ')
	if [ -n "$dp" ]; then kill $dp 2>/dev/null || true; fi
	# A dying daemon can still write into the temp dir for a moment.
	local tries=0
	while [ "$tries" -lt 10 ]; do
		rm -rf "$D" 2>/dev/null
		if [ ! -e "$D" ]; then break; fi
		sleep 0.2
		tries=$((tries + 1))
	done
	exit "$code"
}
trap cleanup EXIT INT TERM HUP

start_window() {
	rm -f "$CTL"
	"$BIN" --control "$CTL" >>"$D/window.log" 2>&1 &
	WPID=$!
	WINDOW_PIDS="$WINDOW_PIDS $WPID"
	local n=0
	while [ "$n" -lt 300 ]; do
		if [ -S "$CTL" ]; then return 0; fi
		if ! kill -0 "$WPID" 2>/dev/null; then return 1; fi
		sleep 0.1
		n=$((n + 1))
	done
	return 1
}

close_window() {
	[ -n "$WPID" ] || return 0
	"$BIN" ctl --control "$CTL" quit >/dev/null 2>&1 || true
	local n=0
	while [ "$n" -lt 50 ]; do
		kill -0 "$WPID" 2>/dev/null || break
		sleep 0.2
		n=$((n + 1))
	done
	if kill -0 "$WPID" 2>/dev/null; then
		kill "$WPID" 2>/dev/null || true
		wait "$WPID" 2>/dev/null || true
	fi
	WPID=""
	rm -f "$CTL"
}

# --- helpers ---------------------------------------------------------------

c() { "$BIN" ctl --control "$CTL" "$@" 2>/dev/null; }

# `dump` folds elements that share a structural path into one, so a canvas with
# two identical rows reports one; `tree` counts every match.
role_count() {
	local n
	n=$(c "tree [data-role='$1']" | sed -n 's/^.*"count":[[:space:]]*\([0-9][0-9]*\).*$/\1/p' | head -n 1)
	printf '%s' "${n:-0}"
}

canvas_count() { "$BIN" ls --json 2>/dev/null | grep -c '"program": "tern.canvas"' || true; }

poll_until() { # poll_until SECONDS PREDICATE...
	local limit=$1
	shift
	local end=$((SECONDS + limit))
	while :; do
		if "$@"; then return 0; fi
		if [ "$SECONDS" -ge "$end" ]; then return 1; fi
		sleep 0.4
	done
}

numeric() { case ${1:-} in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac; }
numeric_float() { printf '%s' "${1:-}" | grep -qE '^-?[0-9]+(\.[0-9]+)?$'; }

panel_open() { [ "$(role_count agentSidebar.root)" -ge 1 ]; }
panel_closed() { [ "$(role_count agentSidebar.root)" -eq 0 ] && [ "$(canvas_count)" -eq 0 ]; }
rows_at_least() { [ "$(role_count agentSidebar.row)" -ge "$1" ]; }
rows_none() { [ "$(role_count agentSidebar.row)" -eq 0 ]; }
groups_at_least() { [ "$(role_count agentSidebar.session)" -ge "$1" ]; }
state_word_shown() { c "tree [data-role='agentSidebar.meta']" | grep -qiE 'working|idle|needs you|waiting|blocked|done|failed'; }
state_exited() { c "tree [data-role='agentSidebar.meta']" | grep -qi 'exited'; }
cli_row_shown() { c "tree [data-role='agentSidebar.row']" | grep -qiE "${CLI_BIN:-none}|\(cli\)"; }
done_marked() { c "tree [data-role='agentSidebar.meta']" | grep -qi 'done'; }
done_cleared() { ! done_marked; }

send_toggle() { c --file "$HERE/scenarios/toggle.txt" >/dev/null 2>&1 || true; }
close_palette() { c --file "$HERE/scenarios/escape.txt" >/dev/null 2>&1 || true; }
click_row() { c --file "$HERE/scenarios/click-row.txt" >/dev/null 2>&1 || true; }

ensure_panel() {
	local n=0
	while [ "$n" -lt 3 ]; do
		panel_open && return 0
		send_toggle
		poll_until 12 panel_open && return 0
		n=$((n + 1))
	done
	return 1
}

panel_width() {
	c "dump [data-role='agentSidebar.root']" | tr -d ' \n' |
		sed -n 's/.*"rect":\[\([^]]*\)\].*/\1/p' | cut -d, -f3
}

first_agent() {
	local name
	for name in $AGENT_SET; do
		if command -v "$name" >/dev/null 2>&1; then
			printf '%s' "$name"
			return 0
		fi
	done
	return 1
}

# A pane running omp is adopted as an agent block, so the CLI half of the model
# needs an agent Tern leaves in the pane: any of the set but omp.
first_cli_agent() {
	local name
	for name in claude codex opencode gemini aider amp cursor-agent crush goose hermes kimi; do
		if command -v "$name" >/dev/null 2>&1; then
			printf '%s' "$name"
			return 0
		fi
	done
	return 1
}

# tern new tab [SESSION] [LAUNCH] prints the new block's id.
new_tab() {
	local session=${1:-}
	shift || true
	if [ -n "$session" ]; then
		"$BIN" new tab "$session" "$@" 2>/dev/null | tail -n 1 | tr -d '[:space:]'
	else
		"$BIN" new tab "$@" 2>/dev/null | tail -n 1 | tr -d '[:space:]'
	fi
}

agent_tab() { # agent_tab [SESSION] -> block id
	new_tab "${1:-}" --cwd "$D/work" --keep-open -- "$AGENT_BIN"
}

# --- boot ------------------------------------------------------------------

# tern plugin link DIR
link_out=$("$BIN" plugin link "$PLUGIN_DIR" 2>&1)
link_rc=$?

if ! start_window; then
	printf 'FAIL load: Tern did not start: %s\n' "$(tail -n 3 "$D/window.log" 2>/dev/null | tr '\n' ' ')" >&2
	exit 1
fi

# --- load ------------------------------------------------------------------
# tern plugin list
# tern ctl --control EP --file verify/scenarios/palette-sidebar.txt
# tern ctl --control EP 'tree .tn-pal'
LOADED=0
load_problems() {
	[ -f "$LOG" ] || return 1
	tail -n +"$LOG_START" "$LOG" | grep -E 'plugin (window|host) entry failed to load plugin="agent-sidebar"'
}
plugin_listed() { "$BIN" plugin list 2>/dev/null | grep -qE '^agent-sidebar[[:space:]]'; }
palette_lists_command() {
	c --file "$HERE/scenarios/palette-sidebar.txt" >/dev/null 2>&1 || return 1
	c 'tree .tn-pal' | grep -q 'Agent Sidebar'
}

poll_until 12 plugin_listed
list_out=$("$BIN" plugin list 2>&1)
if [ "$link_rc" -ne 0 ]; then
	bad load "tern plugin link failed: $(printf '%s' "$link_out" | tr '\n' ' ' | cut -c1-200)"
elif ! printf '%s' "$list_out" | grep -qE '^agent-sidebar[[:space:]]'; then
	bad load "tern plugin list does not list agent-sidebar"
elif ! printf '%s' "$list_out" | grep -qE '^agent-sidebar .*ready'; then
	bad load "agent-sidebar did not load: $(printf '%s' "$list_out" | tr '\n' ' ' | cut -c1-200)"
elif load_problems >/dev/null 2>&1; then
	bad load "the window entry failed to load: $(load_problems | head -n 1 | cut -c1-200)"
elif ! poll_until 20 palette_lists_command; then
	bad load "the palette never listed an Agent Sidebar command"
else
	ok load
	LOADED=1
fi
close_palette

# --- appear ----------------------------------------------------------------
# tern new tab --cwd DIR --keep-open -- AGENT
# tern ctl --control EP "tree [data-role='agentSidebar.row']"   (row count)
AGENT_BIN=$(first_agent) || AGENT_BIN=""
AGENT_PANE=""
if [ "$LOADED" -ne 1 ]; then
	skp appear "the plugin did not load"
elif [ -z "$AGENT_BIN" ]; then
	skp appear "no coding agent installed (omp, claude, codex, opencode, gemini, aider)"
elif ! ensure_panel; then
	bad appear "the sidebar never opened (cmd+alt+shift+a)"
else
	before=$(role_count agentSidebar.row)
	AGENT_PANE=$(agent_tab)
	if ! numeric "$AGENT_PANE"; then
		bad appear "tern new tab printed no block id: $AGENT_PANE"
		AGENT_PANE=""
	elif ! poll_until 30 rows_at_least "$((before + 1))"; then
		bad appear "no row appeared for $AGENT_BIN (block $AGENT_PANE)"
	elif [ "$(canvas_count)" -lt 1 ]; then
		bad appear "the Agents canvas is missing"
	else
		ok appear
	fi
fi

# --- state -----------------------------------------------------------------
# tern ctl --control EP "tree [data-role='agentSidebar.meta']"
if [ "$LOADED" -ne 1 ]; then
	skp state "the plugin did not load"
elif [ -z "$AGENT_BIN" ]; then
	skp state "no coding agent installed (omp, claude, codex, opencode, gemini, aider)"
elif ! numeric "$AGENT_PANE"; then
	skp state "no agent row to watch (appear failed)"
elif ! poll_until 30 state_word_shown; then
	if state_exited; then
		skp state "the agent exited before it reported a state"
	else
		bad state "the row shows no live state (working, idle, needs you, done)"
	fi
else
	ok state
fi

# --- disappear -------------------------------------------------------------
# tern close BLOCK
if [ "$LOADED" -ne 1 ]; then
	skp disappear "the plugin did not load"
elif ! numeric "$AGENT_PANE"; then
	skp disappear "no agent pane to close (appear failed)"
else
	"$BIN" close "$AGENT_PANE" >/dev/null 2>&1 || true
	if poll_until 20 rows_none; then
		ok disappear
		AGENT_PANE=""
	else
		bad disappear "the row outlived its pane (block $AGENT_PANE)"
	fi
fi

# --- cli -------------------------------------------------------------------
# tern new tab --cwd DIR            (a shell block, not an agent block)
# tern run BLOCK CLI-AGENT          (types the command line and Enter)
# tern close BLOCK
CLI_BIN=$(first_cli_agent) || CLI_BIN=""
if [ "$LOADED" -ne 1 ]; then
	skp cli "the plugin did not load"
elif [ -z "$CLI_BIN" ]; then
	skp cli "no CLI agent installed (omp is adopted as an agent block, not a CLI pane)"
elif ! ensure_panel; then
	bad cli "the sidebar never opened (cmd+alt+shift+a)"
else
	shell_pane=$(new_tab "" --cwd "$D/work")
	if ! numeric "$shell_pane"; then
		bad cli "tern new tab printed no block id: $shell_pane"
	else
		"$BIN" run "$shell_pane" "$CLI_BIN" >/dev/null 2>&1 || true
		if ! poll_until 30 cli_row_shown; then
			bad cli "no row for $CLI_BIN run in a shell pane (block $shell_pane)"
		else
			"$BIN" close "$shell_pane" >/dev/null 2>&1 || true
			if poll_until 20 rows_none; then
				ok cli
			else
				bad cli "the cli row outlived its pane (block $shell_pane)"
			fi
		fi
	fi
fi

# --- done ------------------------------------------------------------------
# VERIFY_AGENT_TURN=1: tern send BLOCK text TEXT ; tern send BLOCK keys Enter
# tern focus BLOCK (another tab, so the agent's tab is not shown)
# tern ctl --control EP --file verify/scenarios/click-row.txt
if [ "$LOADED" -ne 1 ]; then
	skp done "the plugin did not load"
elif [ -z "$AGENT_BIN" ]; then
	skp done "no coding agent installed (omp, claude, codex, opencode, gemini, aider)"
elif [ "${VERIFY_AGENT_TURN:-0}" != 1 ]; then
	skp done "set VERIFY_AGENT_TURN=1 to drive a real agent turn"
elif ! ensure_panel; then
	bad done "the sidebar never opened (cmd+alt+shift+a)"
else
	done_pane=$(agent_tab)
	away_pane=$(new_tab "" --cwd "$D/work" --keep-open -- sleep 120)
	if ! numeric "$done_pane" || ! numeric "$away_pane"; then
		bad done "tern new tab printed no block id"
	elif ! poll_until 30 rows_at_least 1; then
		bad done "no row appeared for the agent (block $done_pane)"
	else
		"$BIN" send "$done_pane" text 'reply with the single word ok' >/dev/null 2>&1 || true
		"$BIN" send "$done_pane" keys Enter >/dev/null 2>&1 || true
		"$BIN" focus "$away_pane" >/dev/null 2>&1 || true
		if ! poll_until 180 done_marked; then
			bad done "the finished turn was never marked done"
		else
			click_row
			if poll_until 15 done_cleared; then
				ok done
			else
				bad done "the done mark survived the row click"
			fi
		fi
		"$BIN" close "$away_pane" >/dev/null 2>&1 || true
		"$BIN" close "$done_pane" >/dev/null 2>&1 || true
	fi
fi

# --- group -----------------------------------------------------------------
# tern new tab --cwd DIR --keep-open -- AGENT      (the shown session)
# tern new session NAME
# tern new tab NAME --cwd DIR --keep-open -- AGENT
if [ "$LOADED" -ne 1 ]; then
	skp group "the plugin did not load"
elif [ -z "$AGENT_BIN" ]; then
	skp group "no coding agent installed (omp, claude, codex, opencode, gemini, aider)"
elif ! ensure_panel; then
	bad group "the sidebar never opened (cmd+alt+shift+a)"
else
	first_pane=$(agent_tab)
	"$BIN" new session verify-group >/dev/null 2>&1 || true
	second_pane=$(agent_tab verify-group)
	if ! numeric "$first_pane" || ! numeric "$second_pane"; then
		bad group "tern new tab printed no block id"
	elif ! poll_until 40 groups_at_least 2; then
		bad group "agents in two sessions did not group apart"
	else
		ok group
	fi
	"$BIN" close "$second_pane" >/dev/null 2>&1 || true
	"$BIN" close "$first_pane" >/dev/null 2>&1 || true
fi

# --- toggle ----------------------------------------------------------------
# tern ctl --control EP "dump [data-role='agentSidebar.root']"   (its width)
# tern ctl --control EP --file verify/scenarios/toggle.txt
if [ "$LOADED" -ne 1 ]; then
	skp toggle "the plugin did not load"
elif ! ensure_panel; then
	bad toggle "the sidebar never opened (cmd+alt+shift+a)"
else
	w1=$(panel_width)
	send_toggle
	if ! poll_until 15 panel_closed; then
		bad toggle "the chord did not hide the sidebar"
	else
		send_toggle
		if ! poll_until 15 panel_open; then
			bad toggle "the chord did not show the sidebar again"
		else
			w2=$(panel_width)
			if [ -n "$w1" ] && [ -n "$w2" ] && numeric_float "$w1" && numeric_float "$w2"; then
				if awk -v a="$w1" -v b="$w2" 'BEGIN { d = a - b; if (d < 0) d = -d; exit (d > 24) ? 1 : 0 }'; then
					ok toggle
				else
					bad toggle "the width changed from $w1 to $w2 across the toggle"
				fi
			else
				ok toggle
			fi
		fi
	fi
fi

# --- restart ---------------------------------------------------------------
# tern ctl --control EP quit ; tern --control EP (a fresh window, same config)
if [ "$LOADED" -ne 1 ]; then
	skp restart "the plugin did not load"
elif ! panel_open; then
	skp restart "the sidebar is not open to carry across a restart"
else
	close_window
	if ! start_window; then
		bad restart "Tern did not start again"
	elif ! poll_until 45 panel_open; then
		bad restart "the sidebar did not reopen from its saved state"
	else
		ok restart
	fi
fi

# --- budget ----------------------------------------------------------------
# tail -n +LOG_START ~/Library/Logs/Tern/tern.log, narrowed to this run's pids
if [ "$LOADED" -ne 1 ]; then
	skp budget "the plugin did not load, so no hook ran"
elif [ ! -f "$LOG" ]; then
	skp budget "no Tern log at $LOG"
else
	pids=" $(printf '%s' "$WINDOW_PIDS" | tr -s ' ') $(lsof -t -- "$TERN_DAEMON_SOCKET" 2>/dev/null | tr '\n' ' ') "
	delta=$(tail -n +"$LOG_START" "$LOG" 2>/dev/null)
	ours=$(printf '%s\n' "$delta" | awk -v p="$pids" 'index(p, " " $2 " ") > 0')
	if [ -z "$ours" ]; then
		ours=$(printf '%s\n' "$delta" | grep -F 'agent-sidebar')
	fi
	errs=$(printf '%s\n' "$ours" | grep -Ei 'failed to load|error=|uncaught|lua error' | head -n 3)
	paused=$(printf '%s\n' "$ours" | grep -i 'paused its' | head -n 3)
	if [ -n "$errs" ]; then
		bad budget "the plugin logged an error: $(printf '%s' "$errs" | head -n 1 | cut -c1-200)"
	elif [ -n "$paused" ]; then
		bad budget "a hook overran its budget: $(printf '%s' "$paused" | head -n 1 | cut -c1-200)"
	else
		ok budget
	fi
fi

# --- report ----------------------------------------------------------------

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
if [ "$fail" -ne 0 ]; then exit 1; fi
exit 0
