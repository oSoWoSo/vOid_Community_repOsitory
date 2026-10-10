#!/usr/bin/env bash
# vim: set et sw=4 ts=4 filetype=sh :
#
# Detect a newer upstream version for a template.
#
# Usage: detect-update.sh <pkgname> [repo-root]
#
# Prints "<pkgname> <old> <new>" when a newer version exists, prints nothing
# when the template is up to date and exits 2 on error. RC_FIND_NEW=0 means
# "found nothing new".
#
# srcpkgs/<pkg>/update is the single source of truth for what "latest" means
# (site/pattern/ignore plus the sort -V + xbps-uhelper cmpver ordering), so we
# delegate to ./xbps-src update-check instead of reimplementing that logic.
# The prerelease policy therefore stays exactly the one the templates ask
# for: "latest" endpoints and the ignore= globs, never a guess based on
# release flags.
#
# xbps-src update-check needs the xbps-* tools on the host. A stock GitHub
# Actions runner has none and voidlinux/void-glibc ships only xbps-uhelper --
# which happens to be the only tool update-check actually executes:
#
#   * xbps-uhelper cmpver (a pure version comparison, no network) is answered
#     by that container. update-check calls it once per candidate version and
#     prints "pkg-old -> pkg-new" when it returns 255, so the shim records the
#     pairs and returns 255 for every one of them; the recorded pairs are then
#     resolved in a single container run.
#   * xbps-uhelper -V (xbps-src's own version gate) is delegated as well.
#   * the remaining tools are only probed with `command -v`, so stubs suffice.
#
# When a real xbps-uhelper is installed (a Void host) it is used directly,
# which makes the script testable outside CI. Set FORCE_CMPVER_CONTAINER=1 to
# exercise the container path anyway.

set -euo pipefail

RC_FIND_NEW=0
RC_ERROR=2

pkg=${1:?usage: detect-update.sh <pkgname> [repo-root]}
root=${2:-$(git rev-parse --show-toplevel)}
image=${VOID_IMAGE:-ghcr.io/void-linux/void-glibc:20261001R1}

cd "$root"

msg() {
	printf '%s\n' "$*" >&2
}

# xbps versions carry neither dashes nor underscores while several upstreams do
# (librewolf tags 157.0.1-1, some releases use 1.2.3_rc1). Normalizing before
# the comparison keeps xbps-uhelper cmpver -- which orders those three spellings
# of the same release inconsistently -- from picking the wrong winner.
normalize() {
	local ver=${1//-/_}
	printf '%s' "${ver//_/.}"
}

fail() {
	printf '::error::%s\n' "$*" >&2
	exit "$RC_ERROR"
}

# Symlinked template directories (the -devel aliases) are never bumped.
if [ -L "srcpkgs/$pkg" ]; then
	fail "srcpkgs/$pkg is a symlink, refusing to bump it"
fi

tpl="srcpkgs/$pkg/template"
[ -f "$tpl" ] || fail "template not found: $tpl"

old=$(sed -n 's/^version=//p' "$tpl" | head -1 | tr -d '"')
[ -n "$old" ] || fail "could not read version from $tpl"

# llama.cpp & friends point `site` at api.github.com, which allows only 60
# unauthenticated requests per hour and per runner IP.
if [ -n "${GITHUB_TOKEN:-}" ]; then
	printf 'machine api.github.com login x-access-token password %s\n' \
		"$GITHUB_TOKEN" >"$HOME/.netrc"
	chmod 600 "$HOME/.netrc"
fi

if [ "${FORCE_CMPVER_CONTAINER:-0}" = 1 ] || ! command -v xbps-uhelper >/dev/null 2>&1; then
	shim=$(mktemp -d)
	trap 'rm -rf "$shim"' EXIT

	for tool in xbps-install xbps-query xbps-rindex xbps-reconfigure \
		xbps-remove xbps-create xbps-uchroot xbps-uunshare; do
		printf '#!/bin/sh\nexit 0\n' >"$shim/$tool"
		chmod +x "$shim/$tool"
	done

	pairs="$shim/cmpver-pairs"
	: >"$pairs"

	cat >"$shim/xbps-uhelper" <<EOF
#!/usr/bin/env bash
# Package comparisons always carry a pkgver ("<pkg>-<version>_1"); anything
# else (xbps-src's own "xbps-uhelper cmpver <xbps version> <required>" gate)
# is answered by the real tool.
case "\${3:-}" in
*_1)
	want=\${3#"$pkg-"}
	want=\${want%_1}
	want=\${want//-/_}
	want=\${want//_/.}
	printf '%s\t%s\n' "\$2" "${pkg}-\${want}_1" >>"$pairs"
	exit 255
	;;
esac
exec docker run --rm -i "$image" xbps-uhelper "\$@"
EOF
	chmod +x "$shim/xbps-uhelper"

	PATH="$shim:$PATH" ./xbps-src update-check "$pkg" >"$shim/out" 2>&1 || true

	if [ ! -s "$pairs" ]; then
		msg "$(<"$shim/out")"
		printf '::warning::%s: no version candidates found (site unreachable or update file broken?)\n' "$pkg" >&2
		exit "$RC_FIND_NEW"
	fi

	# Resolve the recorded comparisons in one container run: cmpver returns
	# 255 when the second version is the newer one. The highest candidate
	# wins, not simply the last one -- "sort -V" and xbps version ordering
	# disagree often enough to matter (157.0.1-1 vs 157.0.1.1).
	docker run --rm -i -v "$shim:/w" "$image" sh -uc '
		tab=$(printf "\t")
		max=
		while IFS="$tab" read -r have want; do
			rc=0
			xbps-uhelper cmpver "$have" "$want" || rc=$?
			[ "$rc" = 255 ] || continue
			if [ -z "$max" ]; then
				max=$want
				continue
			fi
			rc=0
			xbps-uhelper cmpver "$max" "$want" || rc=$?
			[ "$rc" = 255 ] && max=$want
		done < /w/cmpver-pairs
		if [ -n "$max" ]; then printf "%s\n" "$max"; fi
		exit 0
	' >"$shim/newer" || fail "cmpver batch failed"

	new=$(tail -n1 "$shim/newer")
	new=${new#"$pkg-"}
	new=${new%_1}
	new=$(normalize "$new")
else
	out=$(./xbps-src update-check "$pkg" 2>&1) || true
	candidates=$(printf '%s\n' "$out" |
		sed -n "s|^${pkg}-[^ ]* -> ${pkg}-\(.*\)\$|\1|p")
	new=
	while IFS= read -r candidate; do
		[ -n "$candidate" ] || continue
		candidate=$(normalize "$candidate")
		if [ -z "$new" ]; then
			new=$candidate
			continue
		fi
		rc=0
		xbps-uhelper cmpver "${pkg}-${new}_1" "${pkg}-${candidate}_1" || rc=$?
		[ "$rc" = 255 ] && new=$candidate
	done <<<"$candidates"
fi

[ -n "$new" ] || exit "$RC_FIND_NEW"

if [ "$new" = "$old" ]; then
	msg "$pkg is already at $old"
	exit "$RC_FIND_NEW"
fi

printf '%s %s %s\n' "$pkg" "$old" "$new"
