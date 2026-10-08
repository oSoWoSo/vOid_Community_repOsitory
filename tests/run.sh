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
	/^surf_curl\(\)/      {p=1}
	/^surf_diagnose\(\)/  {p=1}
	/^surf_retry_loop\(\)/{p=1}
	/^surf_retry\(\)/     {p=1}
	/^surf_mkcol\(\)/     {p=1}
	/^surf_mkcol_try\(\)/ {p=1}
	/^fetch_repodata\(\)/ {p=1}
	/^upload_file\(\)/   {p=1}
	/^read_template_fields/{p=1}
	/^feed_xml_escape/     {p=1}
	/^feed_urls_from_nvchecker/{p=1}
	/^feed_urls_from_homepage/{p=1}
	/^feed_opml_has/       {p=1}
	p {print}
	p && /^}$/             {p=0}
' "$SCRIPT_DIR/ocoman")"

# Mirrors ocoman's Surfer defaults; individual sections override them.
# Every helper above reads these, so they must exist before the first call.
export SURF_ATTEMPTS=4 SURF_BACKOFF=0
export SURF_DEADLINE=1500 SURF_CONNECT_TIMEOUT=20 SURF_MAX_TIME=300 SURF_BACKOFF_MAX=30
export SURF_SKIP_DELETE=1 SURF_DELETE_ORPHANS=0 SURFER_URL='https://repo.osowoso.org'

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

echo '== feed (feed.opml) helpers =='

NVCONF="$PWD/nvchecker.toml"
FEED_OPML="$PWD/feed.opml"

cat > "$NVCONF" <<'EOF'
[__config__]
oldver = "old_ver.json"

[aquamarine]
source = "github"
use_max_tag = true
github = "hyprwm/aquamarine"
prefix = "v"

["quickshell+"]
source = "gitea"
use_max_tag = true
gitea = "quickshell/quickshell"
host = "git.outfoxxed.me"
prefix = "v"

[hyprlock]
source = "github"
use_max_tag = true
github = "hyprwm/${pkgname}"
prefix = "v"

[sdkmanager]
source = "gitlab"
use_max_tag = true
gitlab = "fdroid/sdkmanager"
host = "gitlab.com"

[python3-textual]
source = "pypi"
pypi = "textual"
EOF

feed_urls_from_nvchecker aquamarine
it 'nvchecker github rc';   assert_rc $? 0
it 'nvchecker github xml';  assert_eq "$_feed_xml_url"  'https://github.com/hyprwm/aquamarine/tags.atom'
it 'nvchecker github html'; assert_eq "$_feed_html_url" 'https://github.com/hyprwm/aquamarine/releases'

feed_urls_from_nvchecker 'quickshell+'
it 'nvchecker gitea xml';  assert_eq "$_feed_xml_url"  'https://git.outfoxxed.me/quickshell/quickshell/tags.rss'
it 'nvchecker gitea html'; assert_eq "$_feed_html_url" 'https://git.outfoxxed.me/quickshell/quickshell/tags'

feed_urls_from_nvchecker hyprlock
it 'nvchecker pkgname subst'; assert_eq "$_feed_xml_url" 'https://github.com/hyprwm/hyprlock/tags.atom'

feed_urls_from_nvchecker sdkmanager
it 'nvchecker gitlab xml';  assert_eq "$_feed_xml_url"  'https://gitlab.com/fdroid/sdkmanager/-/tags?format=atom'
it 'nvchecker gitlab html'; assert_eq "$_feed_html_url" 'https://gitlab.com/fdroid/sdkmanager/-/tags'

it 'nvchecker pypi rc'
feed_urls_from_nvchecker 'python3-textual'
assert_rc $? 1

it 'nvchecker missing rc'
feed_urls_from_nvchecker no-such-pkg
assert_rc $? 1

rm -f "$NVCONF"
it 'nvchecker missing file rc'
feed_urls_from_nvchecker aquamarine
assert_rc $? 1

feed_urls_from_homepage 'https://github.com/zen-browser/desktop'
it 'homepage github xml';  assert_eq "$_feed_xml_url"  'https://github.com/zen-browser/desktop/tags.atom'
it 'homepage github html'; assert_eq "$_feed_html_url" 'https://github.com/zen-browser/desktop/releases'

feed_urls_from_homepage 'https://codeberg.org/oSoWoSo/gum'
it 'homepage codeberg xml'; assert_eq "$_feed_xml_url" 'https://codeberg.org/oSoWoSo/gum/tags.rss'

feed_urls_from_homepage 'https://gitlab.com/fdroid/sdkmanager'
it 'homepage gitlab xml'; assert_eq "$_feed_xml_url" 'https://gitlab.com/fdroid/sdkmanager/-/tags?format=atom'

it 'homepage website rc'
feed_urls_from_homepage 'https://hyprland.org/'
assert_rc $? 1

cat > "$FEED_OPML" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<opml version="2.0">
    <body>
        <outline text="All">
            <outline title="Repology" text="Repology" xmlUrl="https://repology.org/a.atom" htmlUrl="https://repology.org/" type="rss"></outline>
        </outline>
        <outline text="package-update">
            <outline title="drako" text="drako" xmlUrl="https://github.com/lucky7xz/drako/tags.atom" htmlUrl="https://github.com/lucky7xz/drako/releases" type="rss"></outline>
            <outline title="quickshell+" text="quickshell+" xmlUrl="https://git.outfoxxed.me/quickshell/quickshell/tags.atom" htmlUrl="https://git.outfoxxed.me/quickshell/quickshell/tags" type="rss"></outline>
        </outline>
    </body>
</opml>
EOF

feed_opml_has drako;       assert_rc $? 0
feed_opml_has 'quickshell+'; assert_rc $? 0
feed_opml_has gofer;       assert_rc $? 1
feed_opml_has _t;          assert_rc $? 1

rm -f "$FEED_OPML"
feed_opml_has drako;       assert_rc $? 1

it 'xml escape'; assert_eq "$(feed_xml_escape 'a&b<c>d"e')" 'a&amp;b&lt;c&gt;d&quot;e'

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
export PATH SURFER_TOKEN=dummy SURFER_USER=dummy-user

export FAKE_CURL_MODE=ok
it 'ok: returns 0'
_list=$(fetch_remote_list https://example.com/repo); _rc=$?
assert_rc "$_rc" 0
it 'ok: parses filenames'
assert_eq "$_list" "$(printf 'foo-1.0_1.x86_64.xbps\nbar-2.0_1.x86_64.xbps')"

export FAKE_CURL_MODE=fail
it 'fail: nonzero rc'
# No retry budget: this section exercises PROPFIND parsing, not resilience.
# A real 25-minute budget here would only make the suite hang.
SURF_DEADLINE=0
_list=$(fetch_remote_list https://example.com/repo 2>/dev/null); _rc=$?
SURF_DEADLINE=1500
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

echo '== surf_curl =='

_ARGV=$(mktemp)
cat > "$_FAKE_BIN/curl" <<'EOF'
#!/bin/sh
# Records argv, one argument per line, then exits 0.
printf '%s\n' "$@" > "$FAKE_CURL_ARGV"
exit 0
EOF
chmod +x "$_FAKE_BIN/curl"

PATH="$_FAKE_BIN:$PATH_BACKUP"
export PATH FAKE_CURL_ARGV="$_ARGV"

SURFER_USER=alice SURFER_TOKEN=s3cret surf_curl -fsS -X PROPFIND https://example.com/repo/
it 'passes user:password via -u'
assert_eq "$(tr '\n' '|' < "$_ARGV")" \
	'-u|alice:s3cret|--connect-timeout|20|--max-time|300|-fsS|-X|PROPFIND|https://example.com/repo/|'

SURFER_USER= SURFER_TOKEN=s3cret surf_curl -sI https://example.com/repo/
it 'never sends an empty -u value'
assert_eq "$(tr '\n' '|' < "$_ARGV")" \
	'-u|:s3cret|--connect-timeout|20|--max-time|300|-sI|https://example.com/repo/|'

SURFER_USER=alice SURFER_TOKEN=s3cret surf_curl -fsS -T pkg.xbps https://example.com/pkg.xbps
it 'a package upload gets no --max-time (truncating it would corrupt the .xbps)'
assert_eq "$(tr '\n' '|' < "$_ARGV")" \
	'-u|alice:s3cret|--connect-timeout|20|-fsS|-T|pkg.xbps|https://example.com/pkg.xbps|'

SURFER_USER=alice SURFER_TOKEN=s3cret surf_curl -fsS --upload-file pkg.xbps https://example.com/pkg.xbps
it '--upload-file also escapes the --max-time cap'
assert_eq "$(tr '\n' '|' < "$_ARGV")" \
	'-u|alice:s3cret|--connect-timeout|20|-fsS|--upload-file|pkg.xbps|https://example.com/pkg.xbps|'

unset FAKE_CURL_ARGV
PATH="$PATH_BACKUP"

echo '== surf_retry / fetch_repodata =='

cat > "$_FAKE_BIN/curl" <<'EOF'
#!/bin/sh
# Scripted fake curl. One directive per line in $FAKE_CURL_SCRIPT:
#   http:<code>     response with that status: body goes to the -o target,
#                   the status is printed (what curl -w '%{http_code}' does)
#   page:<code>:<f> like http:, but the body is the contents of file <f>
#                   (used to serve Cloudron's HTML error page)
#   rc:<n>          fail with exit status n
#   body:<file>     print that file's contents, exit 0
# The invocation count is kept in $FAKE_CURL_COUNT; the last line of the
# script repeats for every further invocation.
[ -n "${FAKE_CURL_ARGV:-}" ] && printf '%s\n' "$@" > "$FAKE_CURL_ARGV"
_n=$(cat "${FAKE_CURL_COUNT:-/dev/null}" 2>/dev/null) || _n=0
[ -n "$_n" ] || _n=0
_n=$((_n + 1))
printf '%s' "$_n" > "$FAKE_CURL_COUNT"
_line=$(sed -n "${_n}p" "$FAKE_CURL_SCRIPT")
[ -n "$_line" ] || _line=$(tail -n 1 "$FAKE_CURL_SCRIPT")
_out='' _prev=''
for _a in "$@"; do
	[ "$_prev" = '-o' ] && _out="$_a"
	_prev="$_a"
done
case "$_line" in
	http:*)
		[ -n "$_out" ] && printf 'payload\n' > "$_out"
		printf '%s' "${_line#http:}"
		exit 0 ;;
	page:*)
		_srv_page=${_line#page:}
		[ -n "$_out" ] && cat "${_srv_page#*:}" > "$_out"
		printf '%s' "${_srv_page%%:*}"
		exit 0 ;;
	body:*)
		cat "${_line#body:}"
		exit 0 ;;
	rc:*)
		exit "${_line#rc:}" ;;
esac
exit 0
EOF
chmod +x "$_FAKE_BIN/curl"

PATH="$_FAKE_BIN:$PATH_BACKUP"
export PATH SURFER_TOKEN=dummy SURFER_USER=dummy-user
export SURF_ATTEMPTS=3 SURF_BACKOFF=0
_ARGV=$(mktemp)
_SCRIPT=$(mktemp)
_COUNT=$(mktemp)
export FAKE_CURL_ARGV="$_ARGV" FAKE_CURL_SCRIPT="$_SCRIPT" FAKE_CURL_COUNT="$_COUNT"

_REPODATA_URL='https://repo.osowoso.org/x86_64/x86_64-repodata'

it '200: downloads and returns 0'
printf 'http:200\n' > "$_SCRIPT"; printf '0' > "$_COUNT"
rm -f repodata
fetch_repodata "$_REPODATA_URL" repodata; _rc=$?
assert_rc "$_rc" 0
it '200: writes the index file'
assert_eq "$(cat repodata 2>/dev/null)" 'payload'

it '404: reports "no index yet" without retrying'
printf 'http:404\n' > "$_SCRIPT"; printf '0' > "$_COUNT"
rm -f repodata
fetch_repodata "$_REPODATA_URL" repodata; _rc=$?
assert_rc "$_rc" 1
it '404: single attempt'
assert_eq "$(cat "$_COUNT")" '1'
it '404: leaves no file behind'
assert_eq "$([ -e repodata ] && echo yes || echo no)" 'no'

it '502 then 200: transient server error is retried'
printf 'http:502\nhttp:200\n' > "$_SCRIPT"; printf '0' > "$_COUNT"
rm -f repodata
fetch_repodata "$_REPODATA_URL" repodata 2>/dev/null; _rc=$?
assert_rc "$_rc" 0
it '502 then 200: two fetches plus one site-root health probe'
assert_eq "$(cat "$_COUNT")" '3'
it '502 then 200: index file present'
assert_eq "$(cat repodata 2>/dev/null)" 'payload'

it 'persistent 5xx: an exhausted deadline gives up with rc 2'
printf 'http:502\nhttp:503\nhttp:502\n' > "$_SCRIPT"; printf '0' > "$_COUNT"
rm -f repodata
SURF_DEADLINE=0 fetch_repodata "$_REPODATA_URL" repodata 2>/dev/null; _rc=$?
assert_rc "$_rc" 2
it 'persistent 5xx: an already-exhausted deadline stops after one attempt'
assert_eq "$(cat "$_COUNT")" '1'
it 'persistent 5xx: no truncated file left behind'
assert_eq "$([ -e repodata ] && echo yes || echo no)" 'no'

it 'the retry budget is wall-clock, not an attempt count'
printf 'http:502\n' > "$_SCRIPT"; printf '0' > "$_COUNT"
rm -f repodata
# One fetch, one 1s backoff, then the 1s budget is spent -- so exactly two
# fetches plus one health probe. An attempt-count budget could not express
# "keep going for 25 minutes"; a wall-clock one can.
SURF_DEADLINE=1 SURF_BACKOFF=1 fetch_repodata "$_REPODATA_URL" repodata 2>/dev/null; _rc=$?
SURF_DEADLINE=1500 SURF_BACKOFF=0
assert_rc "$_rc" 2
assert_eq "$(cat "$_COUNT")" '3'

it 'transport failure is retried'
printf 'rc:7\nhttp:200\n' > "$_SCRIPT"; printf '0' > "$_COUNT"
rm -f repodata
fetch_repodata "$_REPODATA_URL" repodata 2>/dev/null; _rc=$?
assert_rc "$_rc" 0
it 'transport failure: two fetches plus one health probe'
assert_eq "$(cat "$_COUNT")" '3'

it '403: permanent error is not retried'
printf 'http:403\n' > "$_SCRIPT"; printf '0' > "$_COUNT"
rm -f repodata
fetch_repodata "$_REPODATA_URL" repodata 2>/dev/null; _rc=$?
assert_rc "$_rc" 2
it '403: single attempt'
assert_eq "$(cat "$_COUNT")" '1'

it 'surf_retry: keeps caller flags and -u intact'
printf 'rc:0\n' > "$_SCRIPT"; printf '0' > "$_COUNT"
surf_retry -fsS -X PROPFIND https://example.com/repo/; _rc=$?
assert_rc "$_rc" 0
assert_eq "$(tr '\n' '|' < "$_ARGV")" \
	'-u|dummy-user:dummy|--connect-timeout|20|--max-time|300|-fsS|-X|PROPFIND|https://example.com/repo/|'

it 'surf_retry: retries a failed call until it succeeds'
printf 'rc:7\nrc:7\nrc:0\n' > "$_SCRIPT"; printf '0' > "$_COUNT"
surf_retry -fsS -T pkg.xbps https://example.com/pkg.xbps 2>/dev/null; _rc=$?
assert_rc "$_rc" 0
it 'surf_retry: two retries plus one health probe'
assert_eq "$(cat "$_COUNT")" '3'

it 'surf_retry: gives up with rc 1 once the deadline is spent'
printf 'rc:7\n' > "$_SCRIPT"; printf '0' > "$_COUNT"
SURF_DEADLINE=1 SURF_BACKOFF=1 surf_retry -fsS -T pkg.xbps https://example.com/pkg.xbps 2>/dev/null
_rc=$?
SURF_DEADLINE=1500 SURF_BACKOFF=0
assert_rc "$_rc" 1

it 'surf_retry: a rejected password stops the loop immediately'
# Terminal auth failure: the site root answers 401, so there is no point
# burning the remaining budget on requests that cannot succeed.
printf 'rc:22\nhttp:401\n' > "$_SCRIPT"; printf '0' > "$_COUNT"
surf_retry -fsS -X PROPFIND https://example.com/repo/ 2>/dev/null; _rc=$?
assert_rc "$_rc" 1
it 'surf_retry: terminal auth failure: no retry after the probe'
assert_eq "$(cat "$_COUNT")" '2'

printf '<?xml version="1.0"?>\n<D:multistatus xmlns:D="DAV:">\n<D:response><D:href>/x86_64/foo-1.0_1.x86_64.xbps</D:href></D:response>\n</D:multistatus>\n' > "$_SCRIPT.body"
it 'fetch_remote_list: survives a 502 on the first PROPFIND'
printf 'rc:22\nhttp:200\nbody:%s.body\n' "$_SCRIPT" > "$_SCRIPT"; printf '0' > "$_COUNT"
_list=$(fetch_remote_list https://example.com/repo 2>/dev/null); _rc=$?
assert_rc "$_rc" 0
it 'fetch_remote_list: parses the retried response'
assert_eq "$_list" 'foo-1.0_1.x86_64.xbps'
it 'fetch_remote_list: two PROPFINDs plus one health probe'
assert_eq "$(cat "$_COUNT")" '3'

echo '== surf_diagnose =='

it 'healthy site root is reachable'
printf 'http:200\n' > "$_SCRIPT"; printf '0' > "$_COUNT"
surf_diagnose 2>/dev/null; _rc=$?
assert_rc "$_rc" 0
it 'healthy site root: single request'
assert_eq "$(cat "$_COUNT")" '1'

it '401 is reported as a terminal auth failure'
printf 'http:401\n' > "$_SCRIPT"; printf '0' > "$_COUNT"
surf_diagnose 2>/dev/null; _rc=$?
assert_rc "$_rc" 2

it '403 is reported as a terminal auth failure'
printf 'http:403\n' > "$_SCRIPT"; printf '0' > "$_COUNT"
surf_diagnose 2>/dev/null; _rc=$?
assert_rc "$_rc" 2

printf '<html><body><h1>Cloudron: app is not responding</h1></body></html>\n' > "$_SCRIPT.page"
it 'Cloudron "app is not responding" is diagnosed as down, not as an auth problem'
printf 'page:502:%s.page\n' "$_SCRIPT" > "$_SCRIPT"; printf '0' > "$_COUNT"
surf_diagnose 2>/dev/null; _rc=$?
assert_rc "$_rc" 1
it '"app is not responding": single request'
assert_eq "$(cat "$_COUNT")" '1'

it 'an empty 502 body is still diagnosed as down'
printf 'http:502\n' > "$_SCRIPT"; printf '0' > "$_COUNT"
surf_diagnose 2>/dev/null; _rc=$?
assert_rc "$_rc" 1

echo '== surf_mkcol =='

it '405 (collection already exists) counts as success'
printf 'http:405\n' > "$_SCRIPT"; printf '0' > "$_COUNT"
surf_mkcol https://example.com/_webdav/x86_64/; _rc=$?
assert_rc "$_rc" 0
it '405: no retry, single request'
assert_eq "$(cat "$_COUNT")" '1'

it '201 (collection created) counts as success'
printf 'http:201\n' > "$_SCRIPT"; printf '0' > "$_COUNT"
surf_mkcol https://example.com/_webdav/x86_64/; _rc=$?
assert_rc "$_rc" 0

it 'a real failure is retried and then reported'
printf 'http:500\n' > "$_SCRIPT"; printf '0' > "$_COUNT"
SURF_DEADLINE=0 surf_mkcol https://example.com/_webdav/x86_64/ 2>/dev/null; _rc=$?
SURF_DEADLINE=1500
assert_rc "$_rc" 1

echo '== upload_file =='

printf 'xbps-payload' > up.xbps
it 'a failed PUT is reported, not fatal'
# The HEAD probe answers 200 with no Last-Modified, so the upload is attempted
# and fails. upload_file must return 1 so do_upload can collect every failure
# instead of aborting on the first one.
printf 'http:200\nrc:22\n' > "$_SCRIPT"; printf '0' > "$_COUNT"
SURF_DEADLINE=0 upload_file up.xbps https://example.com/_webdav/x86_64/up.xbps 2>/dev/null
_rc=$?
SURF_DEADLINE=1500
assert_rc "$_rc" 1

it 'a successful PUT returns 0'
printf 'http:200\nhttp:200\n' > "$_SCRIPT"; printf '0' > "$_COUNT"
SURF_DEADLINE=0 upload_file up.xbps https://example.com/_webdav/x86_64/up.xbps 2>/dev/null
_rc=$?
SURF_DEADLINE=1500
assert_rc "$_rc" 0

it 'a remote copy that is at least as new is skipped'
# Last-Modified newer than the local file => nothing is uploaded at all.
printf 'last-modified: Thu, 01 Jan 2099 00:00:00 GMT\n' > "$_SCRIPT.mod"
printf 'body:%s.mod\n' "$_SCRIPT" > "$_SCRIPT"; printf '0' > "$_COUNT"
upload_file up.xbps https://example.com/_webdav/x86_64/up.xbps; _rc=$?
assert_rc "$_rc" 0
it 'skipped upload makes a single HEAD request only'
assert_eq "$(cat "$_COUNT")" '1'

unset FAKE_CURL_ARGV FAKE_CURL_SCRIPT FAKE_CURL_COUNT
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
SRCPKGS=srcpkgs SURFER_TOKEN=x SURFER_USER=x ARCH=x86_64 _webdav="https://x/webdav"

_orphans=$(mktemp)
prune_orphans "$(printf '%s\n' \
	'keepme-1.0_1.x86_64.xbps' \
	'alsokeep-2.0_1.x86_64.xbps' \
	'gone-1.0_1.x86_64.xbps' \
	'dropped-3.0_1.x86_64.xbps')" "$_orphans" >/dev/null

it 'orphans file lists only removed packages'
assert_eq "$(sort "$_orphans" | tr '\n' ',')" 'dropped,gone,'

it 'prune_orphans never deletes .xbps files (Surfer 7 crashes on DELETE)'
if [ -s "$_DELETED" ]; then
	assert_eq 'DELETE was issued' 'prune_orphans did not delete'
else
	assert_eq 'ok' 'ok'
fi

rm -f "$_orphans" "$_DELETED"
rm -rf srcpkgs
SCRIPT_DIR="$_SCRIPT_DIR_BACKUP"

echo '== SURF_SKIP_DELETE / SURF_DELETE_ORPHANS =='

# delete_remote must not reach the network unless an operator explicitly opts
# into file deletion (SURF_DELETE_ORPHANS=1); orphan pruning itself must never
# delete. prune_orphans ALWAYS lists packages with no template in srcpkgs/ so
# the index gets stripped even when file deletion is suppressed.
eval "$(awk '
	/^delete_remote\(\)/ {p=1}
	/^prune_orphans\(\)/ {p=1}
	/^delete_orphan_files\(\)/ {p=1}
	p {print}
	p && /^}$/           {p=0}
' "$SCRIPT_DIR/ocoman")"

_PATH_BACKUP="$PATH"
PATH="$_FAKE_BIN:$_PATH_BACKUP"
_COUNT=$(mktemp)
export PATH FAKE_CURL_ARGV="$_ARGV" FAKE_CURL_SCRIPT="$_SCRIPT" FAKE_CURL_COUNT="$_COUNT"
export SURF_SKIP_DELETE=1 SURF_DELETE_ORPHANS=0

it 'delete_remote is a no-op while SURF_SKIP_DELETE=1'
printf 'http:204\n' > "$_SCRIPT"; printf '0' > "$_COUNT"
delete_remote 'https://example.com/_webdav/x86_64/gone-1.0_1.x86_64.xbps'
_rc=$?
assert_rc "$_rc" 0
it 'delete_remote: zero HTTP requests'
assert_eq "$(cat "$_COUNT")" '0'

it 'prune_orphans emits orphan names while deletes are suppressed'
mkdir -p srcpkgs/keepme
: > srcpkgs/keepme/template
SCRIPT_DIR="$PWD" SRCPKGS=srcpkgs _webdav='https://example.com/_webdav'
_orphans=$(mktemp)
: > "$_orphans"
prune_orphans "$(printf '%s\n' \
	'keepme-1.0_1.x86_64.xbps' \
	'gone-1.0_1.x86_64.xbps')" "$_orphans" >/dev/null 2>&1
_rc=$?
assert_rc "$_rc" 0
it 'prune_orphans: zero HTTP requests'
assert_eq "$(cat "$_COUNT")" '0'
it 'prune_orphans lists the orphan even with deletes disabled (so index is stripped)'
assert_eq "$(sort "$_orphans" | tr '\n' ',')" 'gone,'

it 'delete_orphan_files is a no-op when SURF_DELETE_ORPHANS=0'
printf 'http:204\n' > "$_SCRIPT"; printf '0' > "$_COUNT"
delete_orphan_files "$_orphans" "$(printf '%s\n' 'gone-1.0_1.x86_64.xbps')" >/dev/null 2>&1
_rc=$?
assert_rc "$_rc" 0
it 'delete_orphan_files: zero HTTP requests when disabled'
assert_eq "$(cat "$_COUNT")" '0'

it 'delete_orphan_files deletes when SURF_DELETE_ORPHANS=1'
export SURF_DELETE_ORPHANS=1
printf 'http:204\n' > "$_SCRIPT"; printf '0' > "$_COUNT"
SURF_DEADLINE=0 delete_orphan_files "$_orphans" "$(printf '%s\n' \
	'gone-1.0_1.x86_64.xbps' \
	'keepme-1.0_1.x86_64.xbps')" >/dev/null 2>&1
SURF_DEADLINE=1500
if [ "$(cat "$_COUNT")" -gt 0 ]; then
	assert_eq 'ok' 'ok'
else
	assert_eq 'no DELETE was issued' 'ok'
fi
it 'delete_orphan_files only deletes listed orphans'
if grep -q 'keepme' "$_ARGV" 2>/dev/null; then
	assert_eq 'deleted unlisted keepme' 'only listed orphans deleted'
else
	assert_eq 'ok' 'ok'
fi

rm -f "$_orphans"
rm -rf srcpkgs
export SURF_SKIP_DELETE=1 SURF_DELETE_ORPHANS=0
unset FAKE_CURL_ARGV FAKE_CURL_SCRIPT FAKE_CURL_COUNT
PATH="$_PATH_BACKUP"
SCRIPT_DIR="$_SCRIPT_DIR_BACKUP"

echo '== do_upload: arch isolation (P0) =='

# xbps-src leaves every architecture's .xbps in one binpkgs/ directory. An
# unqualified glob therefore republishes foreign arches into this arch's
# directory -- which happened on 2026-09-27 (an aarch64-musl job uploaded
# lunasvg-3.5.0_3.x86_64-musl.xbps). Assert on the source text: the glob is
# the thing that must stay pinned to ${ARCH}.
_DOUPLOAD=$(sed -n '/^do_upload()/,/^}$/p' "$SCRIPT_DIR/ocoman")

it 'new packages are copied with an architecture filter'
assert_eq "$(printf '%s' "$_DOUPLOAD" | grep -c 'cp "${_builddir}"/\*\."${ARCH}"\.xbps ')" '1'

it 'xbps-rindex only indexes this architecture'
assert_eq "$(printf '%s' "$_DOUPLOAD" | grep -c 'xbps-rindex -a \./\*\."${ARCH}"\.xbps')" '1'

it 'both upload loops filter on the architecture'
# Packages and signatures go up in one pass, so the globs share a line.
assert_eq "$(printf '%s' "$_DOUPLOAD" | grep -c 'for _file in \./\*\."${ARCH}"\.xbps \./\*\."${ARCH}"\.xbps\.sig2')" '1'
assert_eq "$(printf '%s' "$_DOUPLOAD" | grep -c 'for _file in \./\*-repodata')" '1'

it 'no unfiltered package glob survives anywhere in do_upload'
assert_eq "$(printf '%s' "$_DOUPLOAD" | grep -cE '\./\*\.xbps|"\$\{_builddir\}"/\*\.xbps')" '0'

it 'packages are uploaded before the index'
_pkg_line=$(printf '%s' "$_DOUPLOAD" | grep -n '==> Uploading packages' | cut -d: -f1)
_idx_line=$(printf '%s' "$_DOUPLOAD" | grep -n '==> Uploading repository index' | cut -d: -f1)
if [ -n "$_pkg_line" ] && [ -n "$_idx_line" ] && [ "$_pkg_line" -lt "$_idx_line" ]; then
	assert_eq 'ok' 'ok'
else
	assert_eq "packages at ${_pkg_line}, index at ${_idx_line}" 'ok'
fi

it 'a failed package upload aborts before the index is published'
assert_eq "$(printf '%s' "$_DOUPLOAD" | grep -c 'remote repodata left untouched')" '1'

it 'a failed repodata-strip aborts the upload instead of republishing a stale index'
# The old code swallowed a strip failure with a warning and kept uploading the
# still-stale repodata; that is exactly how tomlplusplus/tomlplusplus-devel
# stayed advertised (with the .xbps gone) and broke `xbps-src pkg hyprcursor`.
assert_eq "$(printf '%s' "$_DOUPLOAD" | grep -c 'fatal "==> repodata-strip failed')" '1'
assert_eq "$(printf '%s' "$_DOUPLOAD" | grep -c "|| echo '  Warning: repodata-strip failed")" '0'

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

echo '== repo key plists =='

if command -v python3 >/dev/null 2>&1; then
	for _plist in "$SCRIPT_DIR/oco-repo-key.plist"; do
		_plist_have=$(python3 - "$_plist" <<'PYEOF'
import plistlib, base64, hashlib, sys
d = plistlib.load(open(sys.argv[1], 'rb'))
pub = d['public-key']
if d.get('public-key-size') != 4096:
    raise SystemExit('bad public-key-size')
if d.get('signature-by') != 'oSoWoSo <mail@osowoso.org>':
    raise SystemExit('bad signature-by')
if d.get('signature-type') != 'rsa':
    raise SystemExit('bad signature-type')
if not pub.startswith(b'-----BEGIN PUBLIC KEY-----') or not pub.endswith(b'-----END PUBLIC KEY-----\n'):
    raise SystemExit('public-key is not PEM text')
# SSH-style RSA fingerprint; must stay df:ec:10:... so the CI key file
# name keeps matching the repo's index-meta.plist.
pem = pub.decode().strip()
der = base64.b64decode(''.join(pem.split('\n')[1:-1]))
i = 0
assert der[i] == 0x30; i += 1
l = der[i]; i += 1
if l & 0x80:
    nlen = l & 0x7f
    l = int.from_bytes(der[i:i+nlen], 'big'); i += nlen
assert der[i] == 0x30; i += 1
l = der[i]; i += 1
if l & 0x80:
    nlen = l & 0x7f
    l = int.from_bytes(der[i:i+nlen], 'big'); i += nlen
i += l
assert der[i] == 0x03; i += 1
l = der[i]; i += 1
if l & 0x80:
    nlen = l & 0x7f
    l = int.from_bytes(der[i:i+nlen], 'big'); i += nlen
i += 1
assert der[i] == 0x30; i += 1
l = der[i]; i += 1
if l & 0x80:
    nlen = l & 0x7f
    l = int.from_bytes(der[i:i+nlen], 'big'); i += nlen
assert der[i] == 0x02; i += 1
l = der[i]; i += 1
if l & 0x80:
    nlen = l & 0x7f
    l = int.from_bytes(der[i:i+nlen], 'big'); i += nlen
n = der[i:i+l]; i += l
assert der[i] == 0x02; i += 1
l = der[i]; i += 1
if l & 0x80:
    nlen = l & 0x7f
    l = int.from_bytes(der[i:i+nlen], 'big'); i += nlen
e = der[i:i+l]
def ssh_encode(b):
    b = (b'\x00' + b) if b[0] & 0x80 else b
    return len(b).to_bytes(4, 'big') + b
blob = b'\x00\x00\x00\x07ssh-rsa' + ssh_encode(e) + ssh_encode(n)
fp = ':'.join('%02x' % x for x in hashlib.md5(blob).digest())
if fp != 'df:ec:10:ef:5c:03:e9:e0:9e:86:77:08:c2:b5:a8:cb':
    raise SystemExit('fingerprint mismatch: ' + fp)
print('ok')
PYEOF
)
		it "parses and key fingerprint matches: ${_plist#"$SCRIPT_DIR"/}"
		assert_eq "$_plist_have" 'ok'
	done
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

	_titles() {
		python3 -c '
import sys, xml.etree.ElementTree as ET
print(" ".join(i.findtext("title", "").split()[0]
               for i in ET.parse(sys.argv[1]).getroot().iter("item")))
' "$1"
	}

	mkdir -p "$_gf_wd/ts/a/build-results-x86_64" \
		"$_gf_wd/ts/b/build-results-x86_64" \
		"$_gf_wd/ts/c/build-results-x86_64"
	printf 'alpha\t1.0\tok\n' > "$_gf_wd/ts/a/build-results-x86_64/results.tsv"
	printf 'bravo\t1.0\tok\n' > "$_gf_wd/ts/b/build-results-x86_64/results.tsv"
	printf 'charlie\t1.0\tok\n' > "$_gf_wd/ts/c/build-results-x86_64/results.tsv"
	python3 "$SCRIPT_DIR/src/gen-feed.py" update \
		"$_gf_wd/ts.xml" "$_gf_wd/ts/a" 200 2026-09-20T08:00:00Z "$_gf_wd/srcpkgs" >/dev/null
	python3 "$SCRIPT_DIR/src/gen-feed.py" update \
		"$_gf_wd/ts.xml" "$_gf_wd/ts/b" 201 2026-09-20T12:00:00Z "$_gf_wd/srcpkgs" >/dev/null
	python3 "$SCRIPT_DIR/src/gen-feed.py" update \
		"$_gf_wd/ts.xml" "$_gf_wd/ts/c" 202 2026-09-20T06:00:00Z "$_gf_wd/srcpkgs" >/dev/null
	it 'ISO run date: pubDate keeps the time of day'
	grep -q '<pubDate>Sun, 20 Sep 2026 08:00:00 +0000</pubDate>' "$_gf_wd/ts.xml"; assert_rc $? 0
	it 'ISO run date: description shows the bare date only'
	grep -q 'Built on: 2026-09-20' "$_gf_wd/ts.xml"; assert_rc $? 0
	it 'same-day items sort newest first'
	assert_eq "$(_titles "$_gf_wd/ts.xml")" 'bravo alpha charlie'

	mkdir -p "$_gf_wd/leg/build-results-x86_64"
	printf 'legacy\t1.0\tok\n' > "$_gf_wd/leg/build-results-x86_64/results.tsv"
	python3 "$SCRIPT_DIR/src/gen-feed.py" update \
		"$_gf_wd/leg.xml" "$_gf_wd/leg" 300 2026-09-20 "$_gf_wd/srcpkgs" >/dev/null
	it 'legacy date-only run date means midnight UTC'
	grep -q '<pubDate>Sun, 20 Sep 2026 00:00:00 +0000</pubDate>' "$_gf_wd/leg.xml"; assert_rc $? 0

	mkdir -p "$_gf_wd/mix/old/build-results-x86_64" \
		"$_gf_wd/mix/new/build-results-x86_64"
	printf 'zzz\t1.0\tok\n' > "$_gf_wd/mix/old/build-results-x86_64/results.tsv"
	printf 'aaa\t1.0\tok\n' > "$_gf_wd/mix/new/build-results-x86_64/results.tsv"
	python3 "$SCRIPT_DIR/src/gen-feed.py" update \
		"$_gf_wd/mix.xml" "$_gf_wd/mix/old" 400 2026-09-20T08:00:00Z "$_gf_wd/srcpkgs" >/dev/null
	python3 "$SCRIPT_DIR/src/gen-feed.py" update \
		"$_gf_wd/mix.xml" "$_gf_wd/mix/new" 401 2026-09-21 "$_gf_wd/srcpkgs" >/dev/null
	it 'legacy midnight item still sorts by its own date'
	assert_eq "$(_titles "$_gf_wd/mix.xml")" 'aaa zzz'

	mkdir -p "$_gf_wd/off/a/build-results-x86_64" \
		"$_gf_wd/off/b/build-results-x86_64"
	printf 'zzz\t1.0\tok\n' > "$_gf_wd/off/a/build-results-x86_64/results.tsv"
	printf 'aaa\t1.0\tok\n' > "$_gf_wd/off/b/build-results-x86_64/results.tsv"
	python3 "$SCRIPT_DIR/src/gen-feed.py" update \
		"$_gf_wd/off.xml" "$_gf_wd/off/a" 500 2026-09-20T09:00:00Z "$_gf_wd/srcpkgs" >/dev/null
	python3 "$SCRIPT_DIR/src/gen-feed.py" update \
		"$_gf_wd/off.xml" "$_gf_wd/off/b" 501 2026-09-20T12:00:00+02:00 "$_gf_wd/srcpkgs" >/dev/null
	it 'numeric offset: kept in pubDate'
	grep -q '<pubDate>Sun, 20 Sep 2026 12:00:00 +0200</pubDate>' "$_gf_wd/off.xml"; assert_rc $? 0
	it 'numeric offset: sorts by instant, not wall clock'
	assert_eq "$(_titles "$_gf_wd/off.xml")" 'aaa zzz'

	mkdir -p "$_gf_wd/junk/build-results-x86_64"
	printf 'junked\t1.0\tok\n' > "$_gf_wd/junk/build-results-x86_64/results.tsv"
	python3 "$SCRIPT_DIR/src/gen-feed.py" update \
		"$_gf_wd/junk.xml" "$_gf_wd/junk" 600 "not-a-date" "$_gf_wd/srcpkgs" >/dev/null
	it 'unparsable run date: falls back to now instead of aborting'
	grep -q "<pubDate>[A-Za-z]*, [0-9][0-9] [A-Za-z]* $(date -u +%Y) " \
		"$_gf_wd/junk.xml"; assert_rc $? 0

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
echo '== close-update-issues.py =='

if command -v python3 >/dev/null 2>&1; then
	_cui_wd=$(mktemp -d)
	mkdir -p "$_cui_wd/results/build-results-x86_64" \
		"$_cui_wd/results/build-results-aarch64"
	printf 'zen-browser-bin\t1.22.1\tok\nz-fail\t1.0\tok\nbump\t3.2.1\tskip\n' \
		> "$_cui_wd/results/build-results-x86_64/results.tsv"
	printf 'zen-browser-bin\t1.22.1\tok\nz-fail\t1.0\tfail\nbump\t3.2.1\tok\n' \
		> "$_cui_wd/results/build-results-aarch64/results.tsv"

	it 'results: ok/fail versions collected per pkg'
	assert_eq "$(python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cui", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
ok, fail = m.collect_results(sys.argv[2])
print("zok=" + ",".join(sorted(ok.get("zen-browser-bin", []))))
print("zfail=" + ",".join(sorted(fail.get("z-fail", []))))
print("bump=" + ",".join(sorted(ok.get("bump", []))))
' "$SCRIPT_DIR/src/close-update-issues.py" "$_cui_wd/results")" "$(printf 'zok=1.22.1\nzfail=1.0\nbump=3.2.1')"

	it 'issue body: hidden markers + heading fallback parsed'
	assert_eq "$(python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cui", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
body = "**Package:** `zen-browser-bin`\n\n**Upstream version:** `1.22.1`\n\n<!-- package-update:zen-browser-bin -->\n<!-- upstream-version:1.22.1 -->"
print(m.extract_pkg_version(body))
' "$SCRIPT_DIR/src/close-update-issues.py")" "('zen-browser-bin', '1.22.1')"

	it 'issue body: no markers returns None,None'
	assert_eq "$(python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cui", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print(m.extract_pkg_version("no markers here"))
' "$SCRIPT_DIR/src/close-update-issues.py")" '(None, None)'

	it 'results: missing dir yields empty maps, no crash'
	assert_eq "$(python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cui", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print(m.collect_results(sys.argv[2]) == ({}, {}))
' "$SCRIPT_DIR/src/close-update-issues.py" "$_cui_wd/nope")" "True"

	it 'cli: --help exits 0'
	python3 "$SCRIPT_DIR/src/close-update-issues.py" --help >/dev/null 2>&1
	assert_rc $? 0
else
	echo '  (skipped: python3 not on PATH)'
fi

echo
printf 'Passed: %s    Failed: %s\n' "$_PASS" "$_FAIL"
[ "$_FAIL" -eq 0 ] || exit 1
