#!/usr/bin/env bash
set -euo pipefail
package=$(realpath -- "$1")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export APM_ROOT="$work/root" APM_REPO_URL=https://repo.example.test/apm
unset APM_STATE_DIR APM_CONF_DIR
lists="$APM_ROOT/var/lib/apm/apm-conf/lists"
mkdir -p "$lists" "$work/downloads"
hash=$(printf '%0128d' 0)
cat > "$lists/Packages" <<EOF
Package: fake-app
Version: 1
Filename: ./pool/fake-app_1_all.deb
Size: 42
SHA512: $hash

Package: no-sha512
Version: 1
Filename: ./pool/no-sha512_1_all.deb
Size: 42
SHA256: $(printf '%064d' 0)
EOF
before=$(sha256sum "$lists/Packages")
cd "$work/downloads"
out=$("$package/bin/amber-pm-debug" /usr/bin/apt -c /does/not/exist download fake-app --print-uris)
test "$out" = "'https://repo.example.test/apm/pool/fake-app_1_all.deb' fake-app_1_all.deb 42 SHA512:$hash"
test "$before" = "$(sha256sum "$lists/Packages")"
test -z "$(find . -mindepth 1 -print -quit)"
reject() {
    if "$package/bin/amber-pm-debug" "$@" > "$work/rejected.out" 2>/dev/null; then
        echo 'Compatibility entry accepted an unsupported request' >&2
        exit 1
    fi
}
reject bash -c 'touch unexpected'
reject apt install fake-app --print-uris
reject apt download fake-app
reject apt download '$(touch unexpected)' --print-uris
reject apt download no-sha512 --print-uris
test ! -s "$work/rejected.out"
test ! -e unexpected
echo 'PASS: Spark URI compatibility returns authentic cached SHA512 metadata, rejects execution and never downloads'
