#!/bin/bash
HERE=$(dirname $(realpath $0))
rm -fr pkg
cp -r src pkg
${HERE}/build.sh pkg
fakeroot dpkg-deb -b -Z xz pkg/ .
rm -fr pkg
