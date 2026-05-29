#!/bin/sh
# Shared build loop used by both test-pr and build CI jobs.
# Required env: PACKAGES, ARCH, BOOTSTRAP, TEST, NATIVE
# Writes built=true/false to GITHUB_OUTPUT when that variable is set.
. "${GITHUB_WORKSPACE}/extra/src/pkg-helpers.sh"
export PATH="/opt/xbps/usr/bin/:$PATH"
cd /void-packages

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

	arch_flag=''
	if [ "$BOOTSTRAP" != "$ARCH" ]; then
		case "$BOOTSTRAP/$ARCH" in
			x86_64/x86_64-musl)
				arch_flag="-A $ARCH"
				;;
			*)
				_cnc_visited=""
				if _check_nocross_chain "$pkg"; then
					arch_flag="-A $ARCH"
				else
					arch_flag="-a $ARCH"
				fi
				;;
		esac
	fi

	echo "==> Building ${pkg}"
	if sudo -Eu builder ./xbps-src -j"$(nproc)" -s $arch_flag $xbps_test pkg "$pkg"; then
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
