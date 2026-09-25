#!/bin/sh
# HomeLede: re-apply customizations to third-party feeds after `./scripts/feeds update`.
#
# Why this exists: `./scripts/feeds update -a` does a `git pull` on every feed and will
# silently discard any in-place edit made to a feed's source tree.  Our overview-page
# extensions need exactly one such edit, so it is expressed here as an idempotent,
# anchored injection that can be replayed any number of times.
#
# Idempotency: every injected line carries the HOMELEDE-CUSTOM marker.  If the expected
# number of marker lines is already present the injection is skipped -- safe to run
# repeatedly.
#
# Usage:  ./custom/apply-feed-customizations.sh          # apply + verify
#         ./custom/apply-feed-customizations.sh --check   # verify only, no writes
#
# Invoked from prepareCompile.sh right after `./scripts/feeds update -a`.

set -u

MARK='HOMELEDE-CUSTOM'
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

TOPDIR="$(cd "$(dirname "$0")/.." && pwd)" || exit 1

# ---------------------------------------------------------------- target 1 ----
# luci-mod-status: register the luci-app-homestatus overview blocks.
#
# Upstream openwrt/luci discovers overview blocks by *scanning* the include
# directory at runtime (fs.list on /www/luci-static/resources/view/status/include),
# so dropping 95_homestatus*.js in place would be enough.  coolsnowwolf/luci
# rewrote the loader into a hard-coded `includeModules` array, so each block has
# to be registered explicitly.
#
# Two entries are needed because the loader wraps *every* include in exactly one
# cbi-section + one title + one hide button (localStorage-keyed).  Emitting two
# sections from a single include would give two cards but only one hide button.
ST_TARGET='feeds/luci/modules/luci-mod-status/htdocs/luci-static/resources/view/status/index.js'
ST_ANCHOR='include.60_wifi'
ST_MODULES='view.status.include.95_homestatus_disks
view.status.include.95_homestatus_apps'
ST_WANT=2

apply_status_include() {
	_t="$TOPDIR/$ST_TARGET"

	if [ ! -f "$_t" ]; then
		echo "  [FAIL] $ST_TARGET not found -- run './scripts/feeds update -a' first" >&2
		return 1
	fi

	_n=$(grep -c "$MARK" "$_t" || true)
	if [ "$_n" -eq "$ST_WANT" ]; then
		echo "  [ ok ] luci-mod-status: ${_n}x marker present, nothing to do"
		return 0
	fi

	if [ "$_n" -gt 0 ]; then
		echo "  [FAIL] luci-mod-status: found ${_n}x marker, expected ${ST_WANT}" >&2
		echo "         refusing to guess -- restore $ST_TARGET and re-run" >&2
		return 1
	fi

	if [ "$CHECK_ONLY" = "1" ]; then
		echo "  [MISS] luci-mod-status: homestatus blocks are NOT registered"
		return 1
	fi

	# Close the anchor line with a comma and emit every module entry, so the
	# whole injection is a single atomic pass.
	#
	# Line endings are normalised to LF: a CRLF copy (this tree is edited from
	# Windows too) would otherwise leave the \r after the comma and break the
	# emitted JavaScript.
	awk -v anchor="$ST_ANCHOR" -v mark="$MARK" -v mods="$ST_MODULES" '
		function emit(   n, arr, i) {
			n = split(mods, arr, "\n")

			# split() on newline yields a trailing empty field, so drop empties
			# and count only real module names.
			while (n > 0 && arr[n] == "")
				n--

			for (i = 1; i <= n; i++)
				print "			{ name: \x27" arr[i] "\x27 }" (i < n ? "," : "") " /* " mark " */"
		}
		BEGIN { done = 0 }
		{
			line = $0
			sub(/\r$/, "", line)

			if (!done && index(line, anchor) > 0 && index(line, mark) == 0) {
				sub(/,[[:space:]]*$/, "", line)
				print line ","
				emit()
				done = 1
				next
			}

			print line
		}
		END { if (!done) exit 3 }
	' "$_t" > "$_t.homelede-new" || {
		rc=$?
		rm -f "$_t.homelede-new"
		echo "  [FAIL] luci-mod-status: anchor '$ST_ANCHOR' not found (loader rewritten upstream?)" >&2
		return 1
	}

	mv "$_t.homelede-new" "$_t"
	echo "  [done] luci-mod-status: registered homestatus blocks"
	return 0
}

# ---------------------------------------------------------------- verify ------
verify() {
	rc=0

	_t="$TOPDIR/$ST_TARGET"
	for _m in $ST_MODULES; do
		if grep -q "$_m.*$MARK" "$_t" 2>/dev/null; then
			echo "  [ ok ] loader registers $_m"
		else
			echo "  [FAIL] loader does not register $_m" >&2
			rc=1
		fi
	done

	# Syntax-check the patched loader. This has caught a real break: emitting
	# array entries without separators produces valid-looking text that fails
	# to parse, and the page then renders nothing at all.
	#
	# node is a native binary on some build hosts (Windows), where an MSYS
	# style path like /z/... cannot be opened -- it would report a bogus syntax
	# error. Run it from the file's own directory with a bare filename.
	if command -v node >/dev/null 2>&1; then
		if (cd "$(dirname "$_t")" && node --check "$(basename "$_t")") >/dev/null 2>&1; then
			echo "  [ ok ] patched loader parses"
		else
			echo "  [FAIL] patched loader has a syntax error (node --check)" >&2
			rc=1
		fi
	else
		echo "  [warn] node not available - skipped loader syntax check" >&2
	fi

	# The block files themselves live in our own feed package; the injected
	# loader entries are harmless (resolveDefault -> null -> filtered out)
	# while the files are absent.
	for _f in 95_homestatus_disks 95_homestatus_apps; do
		_b="$TOPDIR/feeds/xiaoqingfeng/luci-app-homestatus/htdocs/luci-static/resources/view/status/include/$_f.js"
		if [ -f "$_b" ]; then
			echo "  [ ok ] block source present: $_f.js"
		else
			echo "  [warn] block source missing ($_b)" >&2
		fi
	done

	return $rc
}

echo "HomeLede feed customizations ($([ "$CHECK_ONLY" = 1 ] && echo check || echo apply)):"
apply_status_include || { echo "aborting" >&2; exit 1; }
verify || exit 1
exit 0
