#!/bin/sh

# This script is a fallback option, to ensure that Pot is functional on CheriBSD.
pkg64 install -y git curl pot potnet nmap

if [ ! -d "$HOME/pot" ]; then
    git -C $HOME clone https://github.com/digicatapult/pot --no-progress
    cd $HOME/pot || exit
    for dir in bin etc share; do
        cp -fR ./$dir /usr/local64/
    done
fi

if [ ! -f "/usr/local64/bin/pot" ]; then
    echo "Installing pot failed; files failed to copy to /usr/local64"
else
    manifests="/usr/local/share/freebsd/MANIFESTS"
    mkdir -p $manifests
    releases=$(curl -sS "https://download.cheribsd.org/releases/arm64/aarch64c/" | \
        grep -Eo "\w{1,}\.\w{1,}" | sort -u)

    for release in $releases; do
        curl -sS -C - "https://download.cheribsd.org/releases/arm64/aarch64c/$release/ftp/MANIFEST" > \
        "$manifests/arm64-aarch64c-$release-RELEASE"
    done
fi
