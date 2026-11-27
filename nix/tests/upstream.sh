#!/usr/bin/env bash
# Reuse upstream's tests against the installed Nix scripts. Only the harness's
# generated interpreters, command search path and added bwrap options differ.
set -euo pipefail
package=$1
tests=$2
bash_bin=$3
export BASH_COMPLETION_FILE=$4
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/src/var/lib/apm"
cp -r "$tests" "$work/tests"
chmod -R u+w "$work/tests"
ln -s "$package/usr" "$work/src/usr"
ln -s "$package/share/amber-pm/apm" "$work/src/var/lib/apm/apm"
for script in "$work"/tests/*.sh; do
    sed -i \
        -e "s|#!/bin/bash|#!$bash_bin|g" \
        -e "s|/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin|$PATH|g" \
        "$script"
done
sed -i \
    -e 's|files/ace-run"|files/.ace-run-wrapped"|' \
    -e 's|files/ace-run-pkg"|files/.ace-run-pkg-wrapped"|' \
    -e 's/--proc|--dev|--tmpfs/--unsetenv|--proc|--dev|--tmpfs/' \
    -e 's|/host/usr/share/icons:/host/usr/share/cursors|/host/run/current-system/sw/share/icons:/host/usr/share/icons:/host/usr/share/cursors|' \
    -e 's|/amber-ce-tools/additional-data-dir-in-container:/tmp/a b:/tmp/c|/amber-ce-tools/additional-data-dir-in-container:/usr/local/share:/usr/share|' \
    "$work/tests/run-quoting-test.sh"
export APM_LANG=zh_CN
bash "$work/tests/native-pkg-test.sh"
bash "$work/tests/run-quoting-test.sh"
bash "$work/tests/completion-test.sh"
