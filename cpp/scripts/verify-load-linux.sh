#!/usr/bin/env bash
#
# Verify a Linux MonkSynth.so loads cleanly under the strict loader
# semantics that hosts like Bitwig use (dlopen RTLD_NOW), in clean
# minimal containers for several common distros. This catches the
# class of bug where a static dependency leaks into pango/cairo etc.
# but isn't bundled — the plugin loads on the dev box (which has the
# missing system lib installed) but fails for users on bare distros.
#
# Usage:  ./verify-load-linux.sh <path/to/MonkSynth.so>
#
# Exit status: 0 if all distros pass, 1 if any fail.

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "usage: $0 <path/to/MonkSynth.so>" >&2
    exit 2
fi

PLUGIN_HOST="$(readlink -f "$1")"
if [ ! -f "$PLUGIN_HOST" ]; then
    echo "error: plugin not found: $PLUGIN_HOST" >&2
    exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/dlopen-test.c" <<'EOF'
#include <dlfcn.h>
#include <stdio.h>
int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: %s <plugin.so>\n", argv[0]); return 2; }
    void *h = dlopen(argv[1], RTLD_NOW);
    if (!h) { fprintf(stderr, "dlopen FAIL: %s\n", dlerror()); return 1; }
    fprintf(stdout, "dlopen OK\n");
    dlclose(h);
    return 0;
}
EOF

# Distros to test. Format: "image|family"
# family is 'apt-old' (libpng16-16), 'apt-new' (libpng16-16t64), 'dnf', or 'pacman'.
DISTROS=(
    "ubuntu:22.04|apt-old"   # Linux Mint 21.x base, Ubuntu LTS
    "ubuntu:24.04|apt-new"   # Linux Mint 22.x base, current LTS
    "debian:12|apt-old"      # Debian stable
    "fedora:latest|dnf"      # Fedora / RHEL family
    "archlinux:latest|pacman" # Arch / Manjaro / EndeavourOS / CachyOS
)

# Runtime libraries that the plugin links against dynamically
# (per ldd of a current build). Names per distro family.
declare -A APT_OLD_PKGS=(
    [pkgs]="libxcb1 libxcb-xkb1 libxcb-render0 libxcb-shm0 libexpat1 libpng16-16 libstdc++6 gcc libc6-dev"
)
declare -A APT_NEW_PKGS=(
    [pkgs]="libxcb1 libxcb-xkb1 libxcb-render0 libxcb-shm0 libexpat1 libpng16-16t64 libstdc++6 gcc libc6-dev"
)
declare -A DNF_PKGS=(
    [pkgs]="libxcb xcb-util-keysyms libpng expat libstdc++ gcc glibc-devel"
)
declare -A PACMAN_PKGS=(
    [pkgs]="libxcb expat libpng gcc"
)

pass=0
fail=0
failed_images=()

for entry in "${DISTROS[@]}"; do
    image="${entry%%|*}"
    family="${entry##*|}"

    case "$family" in
        apt-old) install="apt-get -qq update >/dev/null 2>&1 && apt-get -qq install -y --no-install-recommends ${APT_OLD_PKGS[pkgs]} >/dev/null 2>&1" ;;
        apt-new) install="apt-get -qq update >/dev/null 2>&1 && apt-get -qq install -y --no-install-recommends ${APT_NEW_PKGS[pkgs]} >/dev/null 2>&1" ;;
        dnf)     install="dnf -q -y install ${DNF_PKGS[pkgs]} >/dev/null 2>&1" ;;
        pacman)  install="pacman -Sy --noconfirm --needed --noprogressbar ${PACMAN_PKGS[pkgs]} >/dev/null 2>&1" ;;
        *)       echo "unknown family: $family" >&2; exit 2 ;;
    esac

    printf "%-20s ... " "$image"

    output=$(docker run --rm \
        -v "$PLUGIN_HOST:/plugin.so:ro" \
        -v "$WORK/dlopen-test.c:/tmp/dlopen-test.c:ro" \
        -e DEBIAN_FRONTEND=noninteractive \
        "$image" \
        bash -c "set -e; $install; gcc /tmp/dlopen-test.c -o /tmp/t -ldl; /tmp/t /plugin.so" 2>&1) && rc=0 || rc=$?

    if [ "$rc" = 0 ]; then
        echo "OK"
        pass=$((pass+1))
    else
        echo "FAIL"
        echo "$output" | sed 's/^/    /'
        fail=$((fail+1))
        failed_images+=("$image")
    fi
done

echo ""
echo "Passed: $pass / $((pass+fail))"
if [ "$fail" -gt 0 ]; then
    echo "Failed: ${failed_images[*]}"
    exit 1
fi
