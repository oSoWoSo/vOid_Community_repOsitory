#!/bin/sh
# Shared build loop used by both test-pr and build CI jobs.
# Required env: PACKAGES, ARCH, BOOTSTRAP, TEST, NATIVE
# Writes built=true/false to GITHUB_OUTPUT when that variable is set.
. "${GITHUB_WORKSPACE}/extra/.github/pkg-helpers.sh"
export PATH="/opt/xbps/usr/bin/:$PATH"
cd /void-packages

arch=''
cross=false
if [ "$BOOTSTRAP" != "$ARCH" ]; then
	arch="-a $ARCH"
	case "$ARCH" in aarch64*) cross=true ;; esac
fi

xbps_test=''
[ "$TEST" = 1 ] && xbps_test='-Q'

echo "==> Resolving dependencies for: $PACKAGES"
PKGS=$(sudo -Eu builder ./xbps-src $xbps_test sort-dependencies $PACKAGES)

echo "==> Build order with dependencies:"
echo "$PKGS"
echo

BUILT=false
FAILED=false
for pkg in $PKGS; do
	if ! pkg_arch_ok "$pkg" "$ARCH"; then
		echo "==> Skipping ${pkg}: not available for ${ARCH}"
		continue
	fi
	if [ "$cross" = true ] && grep -q '^nocross=' "srcpkgs/${pkg}/template" 2>/dev/null; then
		echo "==> Skipping ${pkg}: nocross (built natively)"
		continue
	fi
	echo "==> Building ${pkg}"
	if sudo -Eu builder ./xbps-src -j"$(nproc)" -s $arch $xbps_test pkg "$pkg"; then
		BUILT=true
	else
		FAILED=true
	fi
	echo
done

[ -n "${GITHUB_OUTPUT:-}" ] && printf 'built=%s\n' "$BUILT" >> "$GITHUB_OUTPUT"
if [ "$FAILED" = true ]; then
	exit 1
fi
exit 0
