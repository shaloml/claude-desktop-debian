#!/usr/bin/env bash

#===============================================================================
# publish-desktop
#
# Replace the Claude Desktop installed on this machine with a fresh build
# of the newest official upstream release.
#
#   1. Resolve the newest official .deb from Anthropic's APT index and
#      compare it against what is installed here. Nothing newer -> exit.
#   2. Download that .deb and verify its SHA-256.
#   3. Build our .deb from it via build.sh --deb (repo pins untouched).
#   4. Stop every running Claude Desktop process.
#   5. Remove the currently installed package.
#   6. Install the freshly built package.
#
# User data in ~/.config/Claude is never touched.
#===============================================================================

readonly PACKAGE_NAME='claude-desktop-unofficial'
readonly LEGACY_PACKAGE='claude-desktop'
readonly APT_BASE='https://downloads.claude.ai/claude-desktop/apt/stable'
readonly CACHE_DIR="$HOME/.cache/claude-desktop-debian/official"

# Seconds to wait for a SIGTERM'd app to exit before escalating to KILL.
readonly TERM_GRACE=15

force=false
dry_run=false
skip_build=false
project_root=''
architecture=''
installed_pkg=''
installed_version=''
built_deb=''
official_deb_local=''

# Argv prefix for the two privileged steps; set by require_sudo(). Empty
# when already root.
sudo_cmd=()

# Assigned by resolve_official_deb(), which check_new_version sources from
# scripts/setup/official-deb.sh.
resolved_official_version=''
resolved_official_filename=''
resolved_official_sha256=''

log() { printf '\033[1;34m[publish-desktop]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[publish-desktop]\033[0m %s\n' "$*" >&2; }
die() {
	printf '\033[1;31m[publish-desktop]\033[0m %s\n' "$*" >&2
	exit 1
}

usage() {
	cat << 'EOF'
Usage: publish-desktop.sh [options]

  --force       Rebuild and reinstall even when no newer version exists.
  --skip-build  Reuse the .deb already present in the project root.
  --dry-run     Print each step without changing anything.
  -h, --help    Show this help.
EOF
}

parse_args() {
	while (( $# > 0 )); do
		case "$1" in
			--force) force=true ;;
			--skip-build) skip_build=true ;;
			--dry-run) dry_run=true ;;
			-h|--help)
				usage
				exit 0
				;;
			*)
				usage >&2
				die "Unknown option: $1"
				;;
		esac
		shift
	done
}

# The skill lives at <root>/.claude/skills/publish-desktop/, so the repo
# root is three levels up unless the harness exports it for us.
resolve_project_root() {
	local script_dir

	if [[ -n ${CLAUDE_PROJECT_DIR:-} && -x $CLAUDE_PROJECT_DIR/build.sh ]]; then
		project_root="$CLAUDE_PROJECT_DIR"
	else
		script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
		project_root="$(cd "$script_dir/../../.." && pwd)"
	fi

	[[ -x $project_root/build.sh ]] ||
		die "build.sh not found under $project_root"
}

preflight() {
	local tool

	for tool in curl wget sha256sum dpkg dpkg-query apt-get; do
		command -v "$tool" > /dev/null 2>&1 ||
			die "Required tool not found: $tool"
	done

	architecture="$(dpkg --print-architecture)"
	case "$architecture" in
		amd64|arm64) ;;
		*) die "Unsupported architecture: $architecture" ;;
	esac
}

# First graphical askpass helper on this box, if any. sudo -A shells out
# to it for the password, which is the only way to authenticate from a
# process with no controlling terminal (an agent session, a hook, cron
# with a desktop).
find_askpass() {
	local helper

	if [[ -n ${SUDO_ASKPASS:-} && -x ${SUDO_ASKPASS:-} ]]; then
		printf '%s\n' "$SUDO_ASKPASS"
		return 0
	fi

	for helper in /usr/bin/ksshaskpass /usr/bin/ssh-askpass \
		/usr/libexec/gcr4-ssh-askpass /usr/libexec/gcr-ssh-askpass; do
		if [[ -x $helper ]]; then
			printf '%s\n' "$helper"
			return 0
		fi
	done
}

# apt/dpkg refuse to work without root. Resolve how we will authenticate
# up front and fail here if we cannot -- never half-way through, after the
# app has been killed and the old package removed.
require_sudo() {
	local askpass

	[[ $dry_run == true ]] && return 0

	if [[ $EUID -eq 0 ]]; then
		sudo_cmd=()
		return 0
	fi

	# A warm sudo timestamp needs no prompt at all.
	if sudo -n true 2>/dev/null; then
		sudo_cmd=(sudo)
		log 'sudo: already authenticated.'
		return 0
	fi

	askpass=$(find_askpass)
	if [[ -n $askpass && -n ${DISPLAY:-}${WAYLAND_DISPLAY:-} ]]; then
		export SUDO_ASKPASS="$askpass"
		log "sudo: prompting for your password via $(basename "$askpass")"
		log 'Look for the password dialog on your desktop.'

		# Prime the timestamp now so the privileged steps later do not
		# each pop their own dialog mid-run.
		sudo -A -v ||
			die 'sudo authentication failed or was cancelled.'

		sudo_cmd=(sudo -A)
		log 'sudo: authenticated.'
		return 0
	fi

	die "sudo needs a password, and this session has no terminal and no
    graphical askpass helper. Run the skill from a real terminal instead:
    bash .claude/skills/publish-desktop/publish-desktop.sh"
}

# Version of the package currently installed under $1, empty when the
# package is absent or left in a config-files-only ('rc') state.
package_version() {
	local pkg="$1" status

	status=$(dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null)
	[[ $status == 'installed' ]] || return 0

	dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null
}

# Both our current package name and the legacy one it replaced can be on
# disk; whichever is installed is the thing we are superseding.
detect_installed() {
	local pkg version

	for pkg in "$PACKAGE_NAME" "$LEGACY_PACKAGE"; do
		version=$(package_version "$pkg")
		if [[ -n $version ]]; then
			installed_pkg="$pkg"
			installed_version="$version"
			log "Installed: $pkg $version"
			return 0
		fi
	done

	log 'Installed: none'
}

#===============================================================================
# Step 1: is there a newer version upstream?
#===============================================================================

# resolve_official_deb() is the repo's own APT-index parser; sourcing it
# keeps this skill correct if the index format ever moves.
check_new_version() {
	# shellcheck source=/dev/null
	source "$project_root/scripts/setup/official-deb.sh" ||
		die 'Failed to source scripts/setup/official-deb.sh'

	log "Querying the official APT index for $architecture..."
	resolve_official_deb "$architecture" ||
		die 'Could not resolve the newest official .deb'

	[[ -n $resolved_official_version ]] ||
		die 'Official APT index returned no version'
	log "Upstream latest: $resolved_official_version"

	if [[ -z $installed_version ]]; then
		log 'Nothing installed yet — proceeding with a fresh install.'
		return 0
	fi

	if dpkg --compare-versions \
		"$installed_version" ge "$resolved_official_version"; then
		if [[ $force == true ]]; then
			warn "Already at $installed_version — continuing (--force)."
			return 0
		fi
		log "No new version: $installed_version is already up to date."
		exit 0
	fi

	log "New version available: $installed_version ->" \
		"$resolved_official_version"
}

#===============================================================================
# Step 2: pull the official .deb
#===============================================================================

fetch_official_deb_local() {
	local url dest

	url="$APT_BASE/$resolved_official_filename"
	dest="$CACHE_DIR/$(basename "$resolved_official_filename")"

	if [[ $dry_run == true ]]; then
		log "[dry-run] Would download $url"
		official_deb_local="$dest"
		return 0
	fi

	mkdir -p "$CACHE_DIR" || die "Cannot create $CACHE_DIR"

	# A cached copy is only trusted if it still matches the index digest.
	if [[ -f $dest ]] &&
		echo "$resolved_official_sha256  $dest" | sha256sum -c - \
			> /dev/null 2>&1; then
		log "Reusing verified download: $dest"
		official_deb_local="$dest"
		return 0
	fi

	log "Downloading $url"
	wget -q --show-progress -O "$dest" "$url" ||
		die "Download failed: $url"

	echo "$resolved_official_sha256  $dest" | sha256sum -c - \
		> /dev/null 2>&1 ||
		die "SHA-256 mismatch on $dest — refusing to build from it"

	log 'SHA-256 verified.'
	official_deb_local="$dest"
}

#===============================================================================
# Step 3: build our .deb from it
#===============================================================================

# build.sh drops the package in the project root. --deb feeds it the .deb
# we just verified, so the repo's OFFICIAL_DEB_* pins stay untouched (it
# prints a pin-mismatch warning; that is expected here).
build_package() {
	local expected

	expected="$project_root/${PACKAGE_NAME}_${resolved_official_version}_${architecture}.deb"

	if [[ $skip_build == true ]]; then
		[[ -f $expected ]] ||
			die "--skip-build, but $expected does not exist"
		log "Reusing existing build: $expected"
		built_deb="$expected"
		return 0
	fi

	if [[ $dry_run == true ]]; then
		log "[dry-run] Would run: ./build.sh --build deb --clean yes" \
			"--deb $official_deb_local"
		built_deb="$expected"
		return 0
	fi

	log 'Building the .deb (this takes a few minutes)...'
	cd "$project_root" || die "Cannot cd to $project_root"

	./build.sh --build deb --clean yes --deb "$official_deb_local" ||
		die 'build.sh failed'

	[[ -f $expected ]] ||
		die "build.sh reported success but $expected is missing"

	built_deb="$expected"
	log "Built: $built_deb"
}

#===============================================================================
# Step 4: stop the running app
#===============================================================================

# Match on /proc/PID/exe, never on the command line: a `pgrep -f
# claude-desktop` also matches this very script (and any shell that has
# the string in its argv), which is how you kill your own session.
claude_pids() {
	local pid exe

	for pid in /proc/[0-9]*; do
		pid="${pid#/proc/}"
		[[ $pid == "$$" || $pid == "$PPID" ]] && continue

		exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null) || continue
		case "$exe" in
			*/claude-desktop|*/claude-desktop/*) printf '%s\n' "$pid" ;;
		esac
	done
}

stop_running_app() {
	local pids waited

	mapfile -t pids < <(claude_pids)
	if (( ${#pids[@]} == 0 )); then
		log 'Claude Desktop is not running.'
		return 0
	fi

	if [[ $dry_run == true ]]; then
		log "[dry-run] Would stop ${#pids[@]} process(es): ${pids[*]}"
		return 0
	fi

	log "Stopping ${#pids[@]} Claude Desktop process(es)..."
	kill -TERM "${pids[@]}" 2>/dev/null

	waited=0
	while (( waited < TERM_GRACE )); do
		mapfile -t pids < <(claude_pids)
		if (( ${#pids[@]} == 0 )); then
			log 'All processes exited cleanly.'
			return 0
		fi
		sleep 1
		(( waited++ ))
	done

	warn "Still running after ${TERM_GRACE}s — sending SIGKILL."
	kill -KILL "${pids[@]}" 2>/dev/null
	sleep 1

	mapfile -t pids < <(claude_pids)
	(( ${#pids[@]} == 0 )) ||
		die "Could not stop: ${pids[*]}"

	log 'All processes stopped.'
}

#===============================================================================
# Step 5: uninstall the current package
#===============================================================================

# `remove`, not `purge`: purge runs the maintainer scripts' purge path,
# and nothing here needs the package's own conffiles gone. User data in
# ~/.config/Claude is not owned by dpkg and is unaffected either way.
uninstall_current() {
	if [[ -z $installed_pkg ]]; then
		log 'Nothing to uninstall.'
		return 0
	fi

	if [[ $dry_run == true ]]; then
		log "[dry-run] Would run: sudo apt-get remove -y $installed_pkg"
		return 0
	fi

	log "Removing $installed_pkg $installed_version..."
	"${sudo_cmd[@]}" apt-get remove -y "$installed_pkg" ||
		die "Failed to remove $installed_pkg"

	log "Removed $installed_pkg."
}

#===============================================================================
# Step 6: install the new package
#===============================================================================

install_new() {
	local version

	if [[ $dry_run == true ]]; then
		log "[dry-run] Would run: sudo apt-get install -y $built_deb"
		return 0
	fi

	log "Installing $(basename "$built_deb")..."
	"${sudo_cmd[@]}" apt-get install -y "$built_deb" ||
		die "Failed to install $built_deb"

	version=$(package_version "$PACKAGE_NAME")
	[[ -n $version ]] ||
		die "$PACKAGE_NAME is not installed after apt-get install"

	log "Installed $PACKAGE_NAME $version."
}

main() {
	parse_args "$@"
	resolve_project_root
	preflight
	detect_installed
	check_new_version
	require_sudo
	fetch_official_deb_local
	build_package
	stop_running_app
	uninstall_current
	install_new

	if [[ $dry_run == true ]]; then
		log 'Dry run complete — nothing was changed.'
		return 0
	fi

	log "Done. Claude Desktop $resolved_official_version is installed."
	log "Launch it from your app menu or run: $PACKAGE_NAME"
}

main "$@"
