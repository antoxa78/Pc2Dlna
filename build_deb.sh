#!/usr/bin/env bash
#
# Build a .deb packaging the Pc2Dlna setup: patched pa_dlna modules +
# a generic user systemd unit.
#
#   ./build_deb.sh
#
# Produces build/Pc2Dlna_<version>_all.deb
#
# The patched modules are installed under usr/local/lib/python3.*/dist-packages
# (Debian python puts this dir BEFORE /usr/lib/python3/dist-packages on
# sys.path), so they shadow the stock pa-dlna package without ever being
# overwritten by an 'apt upgrade' of pa-dlna.
#
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE=pc2dlna
VERSION=1.9
BUILD_DIR="$PROJECT_DIR/build"
ROOT="$BUILD_DIR/${PACKAGE}_${VERSION}"
DEB="$BUILD_DIR/Pc2Dlna_${VERSION}_all.deb"

PYVER="${PYVER:-$(/usr/bin/python3 -c 'import sys; print("python3." + str(sys.version_info.minor))')}"
PYLIB="usr/local/lib/$PYVER/dist-packages"

echo ">> python library dir: $PYLIB"

# Source of the modules: the PRISTINE system pa_dlna ('-s' ignores the user
# site), with patches/ applied here. The package is therefore always exactly
# 'system pa_dlna + patches/', independent of any hand-edited or stale copy in
# ~/.local.
SRC_PKG="$(/usr/bin/python3 -s -c 'import os, pa_dlna; print(os.path.dirname(pa_dlna.__file__))' 2>/dev/null || true)"
if [ -z "$SRC_PKG" ] || [ ! -d "$SRC_PKG" ]; then
    for d in /usr/lib/python3*/dist-packages/pa_dlna; do
        [ -d "$d" ] && SRC_PKG="$d" && break
    done
fi
[ -d "${SRC_PKG:-}" ] || { echo "ERROR: cannot resolve the system pa_dlna package dir" >&2; exit 1; }
if grep -rqs 'local patch' --include='*.py' "$SRC_PKG"; then
    echo "ERROR: $SRC_PKG is already patched (is the pc2dlna .deb installed?)." >&2
    echo "       Build from a pristine pa-dlna: remove pc2dlna and reinstall pa-dlna." >&2
    exit 1
fi
PADLNA_VER="$(dpkg-query -W -f='${Version}' pa-dlna 2>/dev/null || true)"
echo ">> pristine pa_dlna ${PADLNA_VER:-?} from: $SRC_PKG"

PYMINOR="${PYVER#python3.}"

rm -rf "$ROOT"
mkdir -p "$ROOT"/DEBIAN \
         "$ROOT/$PYLIB" \
         "$ROOT/usr/lib/systemd/user" \
         "$ROOT/usr/share/doc/$PACKAGE/examples"

# --- patched pa_dlna modules (no __pycache__, no bundled tests) ----------
cp -a "$SRC_PKG" "$ROOT/$PYLIB/pa_dlna"
find "$ROOT/$PYLIB/pa_dlna" -type d -name __pycache__ -prune -exec rm -rf {} +
rm -rf "$ROOT/$PYLIB/pa_dlna/tests"

# --- apply patches/ (a failing patch aborts the build) ---------------------
for p in "$PROJECT_DIR"/patches/*.patch; do
    if patch -d "$ROOT/$PYLIB/pa_dlna" -p1 --forward --batch < "$p" >/dev/null; then
        echo ">> applied $(basename "$p")"
    else
        echo "ERROR: $(basename "$p") does not apply cleanly to pa-dlna ${PADLNA_VER:-?}" >&2
        exit 1
    fi
done
find "$ROOT/$PYLIB/pa_dlna" \( -name '*.orig' -o -name '*.rej' \) -delete
grep -rqs 'local patch' --include='*.py' "$ROOT/$PYLIB/pa_dlna" \
    || { echo "ERROR: patched tree has no 'local patch' marker" >&2; exit 1; }

# --- generic user systemd unit --------------------------------------------
cat > "$ROOT/usr/lib/systemd/user/pa-dlna.service" <<EOF
[Unit]
Description=pa-dlna: forward PulseAudio/PipeWire streams to DLNA renderers
After=pipewire-pulse.service
Wants=pipewire-pulse.service

[Service]
Type=simple
ExecStart=/usr/bin/pa-dlna -m 15 --loglevel info
Environment=PULSE_SERVER=unix:%t/pulse/native
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

# --- doc ---------------------------------------------------------------------
cp "$PROJECT_DIR/README.md" "$ROOT/usr/share/doc/$PACKAGE/README.md"
install -m 0644 "$PROJECT_DIR/files/pa-dlna.conf" \
    "$ROOT/usr/share/doc/$PACKAGE/examples/pa-dlna.conf"
install -m 0644 "$PROJECT_DIR/files/pipewire-bitperfect-44100.conf" \
    "$ROOT/usr/share/doc/$PACKAGE/examples/pipewire-bitperfect-44100.conf"
cat > "$ROOT/usr/share/doc/$PACKAGE/copyright" <<EOF
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: pa-dlna
Upstream-Contact: Xavier de Gaye <xdegaye@gmail.com>
Source: https://gitlab.com/xdegaye/pa-dlna

Files: usr/local/lib/python3.*/dist-packages/pa_dlna/*
Copyright: 2022-2026 Xavier de Gaye <xdegaye@gmail.com>
License: Expat

Files: *
Copyright: 2026 Anton <anton@asusx555L-Laptop>
License: Expat

License: Expat
 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:
 .
 The above copyright notice and this permission notice shall be included in
 all copies or substantial portions of the Software.
 .
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 THE SOFTWARE.
EOF

# --- control ------------------------------------------------------------------
# The whole pa_dlna package is replaced, so it must match the pa-dlna version
# it was copied from; and it only lives in this Python minor version's dir.
if [ -n "$PADLNA_VER" ]; then
    PADLNA_DEP="pa-dlna (= $PADLNA_VER)"
else
    PADLNA_DEP="pa-dlna (>= 1.0)"
fi
cat > "$ROOT/DEBIAN/control" <<EOF
Package: $PACKAGE
Version: $VERSION
Section: sound
Priority: optional
Architecture: all
Depends: ${PADLNA_DEP}, python3 (>= 3.${PYMINOR}), python3 (<< 3.$((PYMINOR + 1))~), ffmpeg, pipewire-pulse | pulseaudio
Recommends: pavucontrol
Maintainer: Anton <anton@asusx555L-Laptop>
Homepage: https://gitlab.com/xdegaye/pa-dlna
Description: Stream PC audio to DLNA renderers with reliability fixes
 pa-dlna streams a PulseAudio/PipeWire sink to DLNA Media Renderers such as
 the CelMusper DR70 (CelCast).
 .
 This package installs patched pa_dlna modules, shadowing the Debian copy via
 /usr/local/lib/python3.*/dist-packages, that:
   * skip SCPDs using a foreign XML namespace (e.g. Tencent QPlay),
   * do not permanently blacklist a device after a transient UPnP error,
   * use HTTP/1.1 instead of HTTP/1.0 when querying device descriptions,
   * keep the pipeline warm across renderer drops, and
   * auto-restart the stream if the recorder ends unexpectedly.
 .
 Requires the exact pa-dlna version (and Python minor version) the modules were
 built against; rebuild the package after upgrading either.
 .
 Depends are satisfied on most systems by: pa-dlna, ffmpeg, a Pulse server
 (pipewire-pulse or pulseaudio) and pavucontrol for routing apps to the
 renderer sink.
 .
 It also installs a user systemd unit to run the daemon with fast (15 s)
 msearch re-discovery:
   systemctl --user daemon-reload
   systemctl --user enable --now pa-dlna
 .
 NOTE: the patched modules live in the Python version-specific
 /usr/local/lib/python3.X/dist-packages for the Python used at build time.
 When installing on a machine whose python3 minor version differs, rebuild
 the deb there instead:
   PYVER=python3.<minor> ./build_deb.sh
EOF

cat > "$ROOT/DEBIAN/postinst" <<'EOF'
#!/bin/sh
# The daemon runs as a *user* unit, enabled per-user. The only job here is to
# warn about stale user-site copies of pa_dlna (e.g. left by install.sh),
# which shadow /usr/local and would make this package have no effect.
for d in /home/*/.local/lib/python3*/site-packages/pa_dlna \
         /root/.local/lib/python3*/site-packages/pa_dlna; do
    if [ -d "$d" ]; then
        echo "pc2dlna: WARNING: $d shadows the modules of this package." >&2
        echo "pc2dlna: remove it (or re-run install.sh, which moves it aside)." >&2
    fi
done
exit 0
EOF
chmod 0755 "$ROOT/DEBIAN/postinst"

# --- build ---------------------------------------------------------------------
dpkg-deb --build --root-owner-group "$ROOT" "$DEB" >/dev/null
echo
echo ">> built: $DEB"
echo "   size: $(du -h "$DEB" | cut -f1)"

# --- verification ---------------------------------------------------------------
echo ">> aux: dpkg-deb --info check..."
dpkg-deb --info "$DEB" | sed -n '1,12p'
echo ">> aux: unit + module sanity in the deb..."
dpkg-deb --fsys-tarfile "$DEB" | tar -t | grep -E "pa-dlna.service|upnp/network.py$" | head -3

# --- local note -------------------------------------------------------------------
LOCAL_SITE="$(/usr/bin/python3 -m site --user-site)"
if [ -d "$LOCAL_SITE/pa_dlna" ]; then
    echo
    echo "NOTE: this machine also has a copy at $LOCAL_SITE/pa_dlna."
    echo "The user site shadows /usr/local, so it would override this .deb (and"
    echo "pin an old version). To make the .deb the single source of truth:"
    echo "    sudo dpkg -i $DEB"
    echo "    rm -rf $LOCAL_SITE/pa_dlna"
fi