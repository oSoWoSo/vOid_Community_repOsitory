#!/bin/sh
# Test runner for ocoman helpers.
# Usage: tests/run.sh
# Exit status is the number of failed tests (0 on success).

set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")/.." && pwd)

_TEST_TMP=$(mktemp -d)
trap 'rm -rf "$_TEST_TMP"' EXIT INT TERM
cd "$_TEST_TMP" || exit 99

_PASS=0
_FAIL=0
_CURRENT=''

_red()   { printf '\033[0;31m%s\033[0m' "$1"; }
_green() { printf '\033[0;32m%s\033[0m' "$1"; }

it() { _CURRENT="$1"; }

assert_eq() {
	_got="$1" _want="$2"
	if [ "$_got" = "$_want" ]; then
		_PASS=$((_PASS + 1))
		printf '  %s %s\n' "$(_green '✓')" "$_CURRENT"
	else
		_FAIL=$((_FAIL + 1))
		printf '  %s %s\n      got:  %s\n      want: %s\n' \
			"$(_red '✗')" "$_CURRENT" "$_got" "$_want"
	fi
}

assert_rc() {
	_got="$1" _want="$2"
	if [ "$_got" -eq "$_want" ]; then
		_PASS=$((_PASS + 1))
		printf '  %s %s\n' "$(_green '✓')" "$_CURRENT"
	else
		_FAIL=$((_FAIL + 1))
		printf '  %s %s (rc=%s, want=%s)\n' \
			"$(_red '✗')" "$_CURRENT" "$_got" "$_want"
	fi
}

. "$SCRIPT_DIR/src/pkg-helpers.sh"

eval "$(awk '
	/^pkg_name\(\)/        {p=1}
	/^fetch_remote_list/   {p=1}
	/^read_template_fields/{p=1}
	p {print}
	p && /^}$/             {p=0}
' "$SCRIPT_DIR/ocoman")"

echo '== pkg_name =='
it 'plain name';            assert_eq "$(pkg_name 'foo-1.0_1.x86_64')"          'foo'
it '+ in name';             assert_eq "$(pkg_name 'quickshell+-1.0_1.x86_64')"  'quickshell+'
it 'digit in name';         assert_eq "$(pkg_name 'gtk+3-3.24.42_1.x86_64')"    'gtk+3'
it 'hyphenated name';       assert_eq "$(pkg_name 'python3-PyGithub-1.59_1.x86_64')" 'python3-PyGithub'
it 'musl arch suffix';      assert_eq "$(pkg_name 'foo-1.2_1.aarch64-musl')"    'foo'
it 'caller stripped .xbps'; assert_eq "$(pkg_name 'foo-1.0_1.x86_64')"          'foo'
it 'caller passed .xbps';   assert_eq "$(pkg_name 'foo-1.0_1.x86_64.xbps')"     'foo'

echo '== pkg_arch_ok =='

_mktpl() {
	mkdir -p srcpkgs/_t
	if [ -z "$1" ]; then
		: > srcpkgs/_t/template
	else
		printf 'archs="%s"\n' "$1" > srcpkgs/_t/template
	fi
}

_mktpl 'x86_64'
it 'archs=x86_64 vs x86_64';      pkg_arch_ok _t x86_64;       assert_rc $? 0
it 'archs=x86_64 vs aarch64';     pkg_arch_ok _t aarch64;      assert_rc $? 1

_mktpl 'x86_64 aarch64'
it 'multi-arch positive';         pkg_arch_ok _t aarch64;      assert_rc $? 0
it 'multi-arch negative';         pkg_arch_ok _t i686;         assert_rc $? 1

_mktpl '~i686'
it 'exclusion: passes other';     pkg_arch_ok _t x86_64;       assert_rc $? 0
it 'exclusion: blocks excluded';  pkg_arch_ok _t i686;         assert_rc $? 1

_mktpl '*'
it 'glob *: matches everything';  pkg_arch_ok _t aarch64-musl; assert_rc $? 0

_mktpl '*-musl'
it 'glob *-musl: positive';       pkg_arch_ok _t aarch64-musl; assert_rc $? 0
it 'glob *-musl: negative';       pkg_arch_ok _t x86_64;       assert_rc $? 1

_mktpl ''
it 'empty archs (allow all)';     pkg_arch_ok _t aarch64;      assert_rc $? 0

it 'missing template (allow all)'
rm -rf srcpkgs/_t
pkg_arch_ok _t aarch64; assert_rc $? 0

echo '== read_template_fields =='

_mkfull_tpl() {
	mkdir -p srcpkgs/_t
	cat > srcpkgs/_t/template <<'EOF'
# Template file for 'foo'
pkgname=foo
version=1.2.3
revision=1
short_desc="A short description with spaces and = sign"
maintainer="Jane Doe <jane@example.com>"
homepage="https://example.com/foo?bar=baz"
archs="x86_64 ~i686"
license="MIT"
EOF
}

_mkfull_tpl
read_template_fields srcpkgs/_t/template

it 'version';     assert_eq "$_tpl_version"     '1.2.3'
it 'short_desc';  assert_eq "$_tpl_short_desc"  'A short description with spaces and = sign'
it 'maintainer';  assert_eq "$_tpl_maintainer"  'Jane Doe'
it 'homepage';    assert_eq "$_tpl_homepage"    'https://example.com/foo?bar=baz'
it 'archs';       assert_eq "$_tpl_archs"       'x86_64 ~i686'

cat > srcpkgs/_t/template <<'EOF'
version=1.0
version=2.0
EOF
read_template_fields srcpkgs/_t/template
it 'first version wins'; assert_eq "$_tpl_version" '1.0'

: > srcpkgs/_t/template
read_template_fields srcpkgs/_t/template
it 'empty template -> empty version'; assert_eq "$_tpl_version" ''
it 'empty template -> empty archs';   assert_eq "$_tpl_archs"   ''

echo '== fetch_remote_list =='

_FAKE_BIN=$(mktemp -d)

cat > "$_FAKE_BIN/curl" <<'EOF'
#!/bin/sh
# Modes:
#   FAKE_CURL_MODE=ok:        prints minimal valid PROPFIND XML and exits 0
#   FAKE_CURL_MODE=fail:      exits 7 (connection refused) with stderr text
#   FAKE_CURL_MODE=empty:     exits 0 with empty body
case "${FAKE_CURL_MODE:-ok}" in
	ok)
		cat <<'XML'
<?xml version="1.0"?>
<D:multistatus xmlns:D="DAV:">
<D:response><D:href>/x86_64/foo-1.0_1.x86_64.xbps</D:href></D:response>
<D:response><D:href>/x86_64/bar-2.0_1.x86_64.xbps</D:href></D:response>
</D:multistatus>
XML
		exit 0 ;;
	fail)
		printf 'curl: (7) Could not connect\n' >&2
		exit 7 ;;
	empty)
		exit 0 ;;
esac
EOF
chmod +x "$_FAKE_BIN/curl"

PATH_BACKUP="$PATH"
PATH="$_FAKE_BIN:$PATH_BACKUP"
export PATH SURFER_TOKEN=dummy

export FAKE_CURL_MODE=ok
it 'ok: returns 0'
_list=$(fetch_remote_list https://example.com/repo); _rc=$?
assert_rc "$_rc" 0
it 'ok: parses filenames'
assert_eq "$_list" "$(printf 'foo-1.0_1.x86_64.xbps\nbar-2.0_1.x86_64.xbps')"

export FAKE_CURL_MODE=fail
it 'fail: nonzero rc'
_list=$(fetch_remote_list https://example.com/repo 2>/dev/null); _rc=$?
[ "$_rc" -ne 0 ] && _rc=1
assert_rc "$_rc" 1

export FAKE_CURL_MODE=empty
it 'empty: rc 0, empty output'
_list=$(fetch_remote_list https://example.com/repo); _rc=$?
assert_rc "$_rc" 0
it 'empty: output is empty'
assert_eq "$_list" ''
unset FAKE_CURL_MODE

PATH="$PATH_BACKUP"

echo '== prune_orphans =='

rm -rf srcpkgs
mkdir -p srcpkgs/keepme srcpkgs/alsokeep
: > srcpkgs/keepme/template
: > srcpkgs/alsokeep/template

eval "$(awk '
	/^prune_orphans\(\)/ {p=1}
	/^delete_remote\(\)/ {p=1}
	p {print}
	p && /^}$/           {p=0}
' "$SCRIPT_DIR/ocoman")"

_DELETED=$(mktemp)
delete_remote() { printf '%s\n' "$1" >> "$_DELETED"; }
_SCRIPT_DIR_BACKUP="$SCRIPT_DIR"
SCRIPT_DIR="$PWD"
SRCPKGS=srcpkgs SURFER_TOKEN=x ARCH=x86_64 _webdav="https://x/webdav"

_orphans=$(mktemp)
prune_orphans "$(printf '%s\n' \
	'keepme-1.0_1.x86_64.xbps' \
	'alsokeep-2.0_1.x86_64.xbps' \
	'gone-1.0_1.x86_64.xbps' \
	'dropped-3.0_1.x86_64.xbps')" "$_orphans" >/dev/null

it 'orphans file lists only removed packages'
assert_eq "$(sort "$_orphans" | tr '\n' ',')" 'dropped,gone,'

it 'kept packages were not deleted'
if grep -q 'keepme\|alsokeep' "$_DELETED"; then
	assert_eq 'kept package was deleted' 'kept package was not deleted'
else
	assert_eq 'ok' 'ok'
fi

it 'orphan delete_remote was called for both .xbps and .sig2'
assert_eq "$(grep -c 'gone-1.0_1.x86_64.xbps' "$_DELETED")" '2'

rm -f "$_orphans" "$_DELETED"
rm -rf srcpkgs
SCRIPT_DIR="$_SCRIPT_DIR_BACKUP"

echo '== repodata-list.py =='

if command -v python3 >/dev/null 2>&1; then
	_wd=$(mktemp -d)
	(
		cd "$_wd" || exit 1
		python3 -c '
import plistlib
open("index.plist","wb").write(plistlib.dumps({
    "alpha": {"pkgver":"alpha-1_1"},
    "alpha-devel": {"pkgver":"alpha-devel-1_1"},
    "zeta": {"pkgver":"zeta-9_1"},
}, fmt=plistlib.FMT_XML))
'
		tar -cf x86_64-repodata index.plist
		python3 "$SCRIPT_DIR/src/repodata-list.py" x86_64-repodata | sort | tr '\n' ','
	) > "$_wd/out"
	it 'lists all package names'
	assert_eq "$(cat "$_wd/out")" 'alpha,alpha-devel,zeta,'

	(
		cd "$_wd" || exit 1
		python3 -c 'import plistlib; open("index.plist","wb").write(plistlib.dumps({}, fmt=plistlib.FMT_XML))'
		tar -cf empty-repodata index.plist
		python3 "$SCRIPT_DIR/src/repodata-list.py" empty-repodata
	) > "$_wd/out"; _rc=$?
	it 'empty index: rc 0';        assert_rc "$_rc" 0
	it 'empty index: no output';   assert_eq "$(cat "$_wd/out")" ''

	python3 "$SCRIPT_DIR/src/repodata-list.py" >/dev/null 2>&1; _rc=$?
	it 'missing arg: rc 2';        assert_rc "$_rc" 2

	echo bogus > "$_wd/garbage"
	python3 "$SCRIPT_DIR/src/repodata-list.py" "$_wd/garbage" >/dev/null 2>&1; _rc=$?
	it 'garbage input: rc 1';      assert_rc "$_rc" 1

	if command -v zstd >/dev/null 2>&1; then
		(
			cd "$_wd" || exit 1
			python3 -c '
import plistlib
open("index.plist","wb").write(plistlib.dumps({
    "zst-a": {"v":1}, "zst-b": {"v":2},
}, fmt=plistlib.FMT_XML))
'
			tar -cf zst.tar index.plist
			zstd -q -o zst-repodata zst.tar
			python3 "$SCRIPT_DIR/src/repodata-list.py" zst-repodata | sort | tr '\n' ','
		) > "$_wd/out"
		it 'zstd input: lists all entries'
		assert_eq "$(cat "$_wd/out")" 'zst-a,zst-b,'

		(
			cd "$_wd" || exit 1
			python3 "$SCRIPT_DIR/src/repodata-strip.py" zst-repodata zst-a >/dev/null
			head -c 4 zst-repodata | od -An -tx1 | tr -d ' \n'
		) > "$_wd/out"
		it 'zstd strip: output is still zstd'
		assert_eq "$(cat "$_wd/out")" '28b52ffd'

		(
			cd "$_wd" || exit 1
			python3 "$SCRIPT_DIR/src/repodata-list.py" zst-repodata | tr '\n' ','
		) > "$_wd/out"
		it 'zstd strip: surviving entry is correct'
		assert_eq "$(cat "$_wd/out")" 'zst-b,'
	else
		echo '  (skipped: zstd CLI not on PATH)'
	fi

	rm -rf "$_wd"
else
	echo '  (skipped: python3 not on PATH)'
fi

echo '== repodata-strip.py =='

if command -v python3 >/dev/null 2>&1; then
	_workdir=$(mktemp -d)
	(
		cd "$_workdir" || exit 1
		python3 -c '
import plistlib
with open("index.plist", "wb") as f:
    f.write(plistlib.dumps({
        "alpha": {"pkgver": "alpha-1_1"},
        "beta":  {"pkgver": "beta-2_1"},
        "gamma": {"pkgver": "gamma-3_1"},
    }, fmt=plistlib.FMT_XML))
'
		tar -cf x86_64-repodata index.plist
		python3 "$SCRIPT_DIR/src/repodata-strip.py" \
			x86_64-repodata beta nope >/dev/null
		tar -xOf x86_64-repodata index.plist | python3 -c '
import sys, plistlib
print(",".join(sorted(plistlib.loads(sys.stdin.buffer.read()).keys())))
'
	) > "$_workdir/out"
	it 'strips listed entry; leaves rest'
	assert_eq "$(cat "$_workdir/out")" 'alpha,gamma'
	rm -rf "$_workdir"
else
	echo '  (skipped: python3 not on PATH)'
fi

echo '== gen-feed.py =='

if command -v python3 >/dev/null 2>&1; then
	_gf_wd=$(mktemp -d)
	mkdir -p "$_gf_wd/results/build-results-x86_64" \
		"$_gf_wd/results/build-results-aarch64" \
		"$_gf_wd/srcpkgs/tor"
	printf 'tor\t0.4.8.11\tok\nfailme\t1.0\tfail\n' > "$_gf_wd/results/build-results-x86_64/results.tsv"
	printf 'tor\t0.4.8.11\tok\n' > "$_gf_wd/results/build-results-aarch64/results.tsv"
	cat > "$_gf_wd/srcpkgs/tor/template" <<'EOF'
version=0.4.8.11
homepage=https://example.org/tor
short_desc="An overlay network"
EOF
	python3 "$SCRIPT_DIR/src/gen-feed.py" update \
		"$_gf_wd/feed.xml" "$_gf_wd/results" 42 2026-09-10 "$_gf_wd/srcpkgs" >/dev/null

	it 'first run: one item per ok pkg'
	assert_eq "$(grep -c '<item>' "$_gf_wd/feed.xml")" '1'
	it 'item title carries pkg+version'
	grep -q '<title>tor 0.4.8.11</title>' "$_gf_wd/feed.xml"; assert_rc $? 0
	it 'guid = pkg-version'
	grep -q 'guid isPermaLink="false">tor-0.4.8.11' "$_gf_wd/feed.xml"; assert_rc $? 0
	it 'ok arches listed, failed arch skipped'
	grep -q 'Archs: aarch64 x86_64' "$_gf_wd/feed.xml"; assert_rc $? 0
	it 'template homepage used as item link'
	grep -q '<link>https://example.org/tor</link>' "$_gf_wd/feed.xml"; assert_rc $? 0
	it 'codeberg is the only template link in description'
	grep -q 'codeberg.org/oSoWoSo/oco/src/branch/OCO/srcpkgs/tor/template">template</a>' "$_gf_wd/feed.xml"; assert_rc $? 0
	grep -vq 'github.com/oSoWoSo/Void_Community_Repository/blob/OCO/srcpkgs/tor/template' "$_gf_wd/feed.xml"; assert_rc $? 0
	it 'CI run link in description'
	grep -q 'actions/runs/42' "$_gf_wd/feed.xml"; assert_rc $? 0
	it 'output is valid XML'
	python3 -c 'import sys, xml.etree.ElementTree as ET; ET.parse(sys.argv[1])' "$_gf_wd/feed.xml"; assert_rc $? 0

	python3 "$SCRIPT_DIR/src/gen-feed.py" update \
		"$_gf_wd/feed.xml" "$_gf_wd/results" 99 2026-09-11 "$_gf_wd/srcpkgs" >/dev/null
	it 'same-version rebuild: no new item'
	assert_eq "$(grep -c '<item>' "$_gf_wd/feed.xml")" '1'
	it 'same-version rebuild: date updated'
	grep -q 'Fri, 11 Sep 2026' "$_gf_wd/feed.xml"; assert_rc $? 0
	it 'same-version rebuild: run link updated'
	grep -q 'actions/runs/99' "$_gf_wd/feed.xml"; assert_rc $? 0

	printf 'tor\t0.4.8.12\tok\n' > "$_gf_wd/results/build-results-x86_64/results.tsv"
	python3 "$SCRIPT_DIR/src/gen-feed.py" update \
		"$_gf_wd/feed.xml" "$_gf_wd/results" 100 2026-09-12 "$_gf_wd/srcpkgs" >/dev/null
	it 'version bump adds new item'
	assert_eq "$(grep -c '<item>' "$_gf_wd/feed.xml")" '2'
	it 'history retains previous version'
	grep -q 'tor-0.4.8.11' "$_gf_wd/feed.xml"; assert_rc $? 0
	it 'history adds new version item'
	grep -q 'tor-0.4.8.12' "$_gf_wd/feed.xml"; assert_rc $? 0

	python3 "$SCRIPT_DIR/src/gen-feed.py" update \
		"$_gf_wd/feed.xml" "$_gf_wd/empty" 100 2026-09-12 "$_gf_wd/srcpkgs" 2>/dev/null >/dev/null
	it 'no results dir: item count unchanged'
	assert_eq "$(grep -c '<item>' "$_gf_wd/feed.xml")" '2'

	mkdir -p "$_gf_wd/cap/build-results-x86_64"
	_i=0
	while [ "$_i" -lt 1100 ]; do
		printf 'pkg%s\t%s.0\tok\n' "$_i" "$_i" >> "$_gf_wd/cap/build-results-x86_64/results.tsv"
		_i=$((_i + 1))
	done
	python3 "$SCRIPT_DIR/src/gen-feed.py" update \
		"$_gf_wd/cap.xml" "$_gf_wd/cap" 100 2026-09-12 "$_gf_wd/srcpkgs" >/dev/null
	it 'cap: feed limited to 1000 items'
	assert_eq "$(grep -c '<item>' "$_gf_wd/cap.xml")" '1000'

	rm -rf "$_gf_wd"
else
	echo '  (skipped: python3 not on PATH)'
fi

echo '== _check_nocross_chain =='

eval "$(awk '
  /^[[:space:]]*_check_nocross_chain\(\)/ { p=1; depth=0 }
  p { print }
  p && /\{/ { depth++ }
  p && /\}/ { depth--; if (depth==0) p=0 }
' "$SCRIPT_DIR/.github/workflows/build.yml")"

_mknc_tpl() {
  local _name="$1"; shift
  mkdir -p "srcpkgs/${_name}"
  : > "srcpkgs/${_name}/template"
  while [ $# -gt 0 ]; do
    printf '%s\n' "$1" >> "srcpkgs/${_name}/template"
    shift
  done
}

it 'missing template returns 1'
rm -rf srcpkgs/ghost
_cnc_visited=""
_check_nocross_chain ghost; assert_rc $? 1

it 'direct nocross returns 0'
_mknc_tpl nc1 'nocross=yes'
_cnc_visited=""
_check_nocross_chain nc1; assert_rc $? 0

it 'no nocross no deps returns 1'
_mknc_tpl plain1
_cnc_visited=""
_check_nocross_chain plain1; assert_rc $? 1

it 'dep via hostmakedepends with nocross returns 0'
_mknc_tpl nc_dep 'nocross=yes'
_mknc_tpl pkg_hmd "hostmakedepends=\"nc_dep\""
_cnc_visited=""
_check_nocross_chain pkg_hmd; assert_rc $? 0

it 'dep via makedepends with nocross returns 0'
_mknc_tpl nc_dep2 'nocross=yes'
_mknc_tpl pkg_mkd "makedepends=\"nc_dep2\""
_cnc_visited=""
_check_nocross_chain pkg_mkd; assert_rc $? 0

it 'dep via depends with nocross returns 0'
_mknc_tpl nc_dep3 'nocross=yes'
_mknc_tpl pkg_dep "depends=\"nc_dep3\""
_cnc_visited=""
_check_nocross_chain pkg_dep; assert_rc $? 0

it 'transitive chain (3 deep) returns 0'
_mknc_tpl nc_leaf 'nocross=yes'
_mknc_tpl chain_b "hostmakedepends=\"nc_leaf\""
_mknc_tpl chain_a "hostmakedepends=\"chain_b\""
_cnc_visited=""
_check_nocross_chain chain_a; assert_rc $? 0

it 'versioned dep (>=) stripped correctly'
_mknc_tpl nc_ver 'nocross=yes'
_mknc_tpl pkg_ver "hostmakedepends=\"nc_ver>=1.0\""
_cnc_visited=""
_check_nocross_chain pkg_ver; assert_rc $? 0

it 'circular dep without nocross returns 1 (no infinite loop)'
_mknc_tpl circ_a "hostmakedepends=\"circ_b\""
_mknc_tpl circ_b "hostmakedepends=\"circ_a\""
_cnc_visited=""
_check_nocross_chain circ_a; assert_rc $? 1

it 'external dep (no template) skipped, returns 1'
_mknc_tpl pkg_ext "hostmakedepends=\"no-such-pkg\""
_cnc_visited=""
_check_nocross_chain pkg_ext; assert_rc $? 1

it 'visited guard prevents re-entry'
_mknc_tpl pkg_guard
_cnc_visited=" pkg_guard"
_check_nocross_chain pkg_guard; assert_rc $? 1

echo
printf 'Passed: %s    Failed: %s\n' "$_PASS" "$_FAIL"
[ "$_FAIL" -eq 0 ] || exit 1
