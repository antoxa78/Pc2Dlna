#!/usr/bin/env bash
#
# Pc2Dlna — bootstrap pa-dlna for streaming this PC's audio to DLNA
# renderers (e.g. the CelMusper DR70) on LMDE/Mint (Debian).
#
# Installs pa-dlna, copies the package into the user site (re-made whenever
# pa-dlna or patches/ change), applies the upstream fixes in patches/, writes the lossless-first config and a user
# systemd service, and starts it.
#
#   ./install.sh [network-interface]   # default: default-route interface
#
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES_DIR="$PROJECT_DIR/files"
PATCHES_DIR="$PROJECT_DIR/patches"

# --- network interface ---------------------------------------------------
NIC="${1:-${NIC:-}}"
[ -z "$NIC" ] && NIC="$(ip -4 route show default 2>/dev/null | awk '/^default/{print $5; exit}' || true)"
if [ -n "$NIC" ]; then
    NICARG=" -n $NIC"
    echo ">> network interface: $NIC (fixed in the unit; re-run install.sh if it changes)"
else
    NICARG=""
    echo ">> no default-route interface found: pa-dlna will use all interfaces"
fi

# --- 1. packages ----------------------------------------------------------
if ! command -v pa-dlna >/dev/null; then
    echo ">> pa-dlna not found, installing via apt (needs sudo)..."
    sudo apt-get install -y pa-dlna pavucontrol
fi
command -v pavucontrol >/dev/null 2>&1 || sudo apt-get install -y pavucontrol >/dev/null 2>&1 || true

# --- 2. patched package into the user site -------------------------------
# Interpreter of the pa-dlna entry point (handles "#!/usr/bin/env python3").
PA_PY="$(head -n1 "$(command -v pa-dlna)" | sed -e 's|^#!||' -e 's|^/usr/bin/env ||' -e 's| .*||')"
[ -n "$PA_PY" ] || PA_PY=python3
USER_SITE="$("$PA_PY" -m site --user-site)"
PKGDIR="$USER_SITE/pa_dlna"
STAMPFILE="$PKGDIR/.pc2dlna-stamp"
mkdir -p "$USER_SITE"

backup_pkgdir() {
    local bak="$PKGDIR.disabled-$(date +%Y%m%d%H%M%S)"
    mv "$PKGDIR" "$bak"
    echo ">> moved the previous user-site copy to $bak (safe to delete)"
}

if dpkg-query -W -f='${Status}' pc2dlna 2>/dev/null | grep -q 'ok installed'; then
    # The .deb ships the patched modules in /usr/local; a user-site copy
    # would shadow it and silently pin an old version.
    echo ">> the pc2dlna .deb is installed and provides the patched modules"
    [ -d "$PKGDIR" ] && backup_pkgdir
else
    # Rebuild the user-site copy whenever pa-dlna or patches/ changed since it
    # was made, so it never silently pins an outdated pa-dlna.
    SYS_VER="$(dpkg-query -W -f='${Version}' pa-dlna 2>/dev/null || echo unknown)"
    PATCH_SUM="$(cat "$PATCHES_DIR"/*.patch | sha256sum | cut -d' ' -f1)"
    STAMP="pa-dlna=$SYS_VER patches=$PATCH_SUM"

    if [ -d "$PKGDIR" ] && [ "$(cat "$STAMPFILE" 2>/dev/null)" = "$STAMP" ]; then
        echo ">> user-site pa_dlna is up to date (pa-dlna $SYS_VER)"
    else
        [ -d "$PKGDIR" ] && backup_pkgdir

        # Pristine system copy ('-s' ignores the user site).
        SYSTEM_PKG="$("$PA_PY" -s -q -c 'import os, pa_dlna; print(os.path.dirname(pa_dlna.__file__))' 2>/dev/null || true)"
        if [ -z "$SYSTEM_PKG" ] || [ ! -d "$SYSTEM_PKG" ]; then
            for d in /usr/lib/python3*/dist-packages/pa_dlna; do
                [ -d "$d" ] && SYSTEM_PKG="$d" && break
            done
        fi
        [ -d "${SYSTEM_PKG:-}" ] || { echo "ERROR: cannot locate the system pa_dlna package" >&2; exit 1; }
        if grep -rqs 'local patch' --include='*.py' "$SYSTEM_PKG"; then
            echo "ERROR: $SYSTEM_PKG is already patched (system copy modified?)." >&2
            echo "       Reinstall it first: sudo apt-get install --reinstall pa-dlna" >&2
            exit 1
        fi
        cp -a "$SYSTEM_PKG" "$PKGDIR"
        echo ">> copied pa_dlna $SYS_VER from $SYSTEM_PKG to $PKGDIR"

        for p in "$PATCHES_DIR"/*.patch; do
            if patch -d "$PKGDIR" -p1 --forward --batch < "$p" >/dev/null; then
                echo ">> applied $(basename "$p")"
            else
                echo "ERROR: $(basename "$p") does not apply cleanly to pa-dlna $SYS_VER" >&2
                echo "       (pa-dlna changed upstream; the patch needs updating)." >&2
                rm -rf "$PKGDIR"
                exit 1
            fi
        done
        echo "$STAMP" > "$STAMPFILE"
    fi
fi

# --- 3. config -------------------------------------------------------------
mkdir -p "$HOME/.config/pa-dlna"
install -m 0644 "$FILES_DIR/pa-dlna.conf" "$HOME/.config/pa-dlna/pa-dlna.conf"
echo ">> wrote $HOME/.config/pa-dlna/pa-dlna.conf"

# --- 3b. PipeWire graph clock (bit-perfect sample-rate routing) -----------
# Run the audio graph at 44.1 kHz so CD-rate sources pass through the garbage
# graph -> null-sink -> monitor -> parec -> encoder -> DAC without resampling,
# and the DAC displays the true source rate instead of 48 kHz.
# Set PC2DLNA_NO_PIPEWIRE=1 to skip this (it changes the clock of the whole
# desktop audio graph and restarts PipeWire, cutting any playing audio).
PW_CONF="$HOME/.config/pipewire/pipewire.conf.d/40-bitperfect-44100.conf"
if [ "${PC2DLNA_NO_PIPEWIRE:-0}" = 1 ]; then
    echo ">> skipping the PipeWire clock config (PC2DLNA_NO_PIPEWIRE=1)"
elif cmp -s "$FILES_DIR/pipewire-bitperfect-44100.conf" "$PW_CONF" 2>/dev/null; then
    echo ">> PipeWire clock config already in place"
else
    mkdir -p "$(dirname "$PW_CONF")"
    install -m 0644 "$FILES_DIR/pipewire-bitperfect-44100.conf" "$PW_CONF"
    echo ">> wrote $PW_CONF"
    if timeout 5 systemctl --user try-restart pipewire pipewire-pulse 2>/dev/null; then
        echo ">> restarted pipewire with the new clock (needs 5-10s to settle)"
    fi
fi

# --- 4. user service --------------------------------------------------------
SYSDIR="$HOME/.config/systemd/user"
mkdir -p "$SYSDIR"
sed "s|@NICARG@|$NICARG|g" "$FILES_DIR/pa-dlna.service" > "$SYSDIR/pa-dlna.service"
systemctl --user daemon-reload
systemctl --user enable --now pa-dlna.service 2>/dev/null || { echo "note: reload the service later (boot session may not accept enable now)"; }
echo ">> installed + started $SYSDIR/pa-dlna.service"

cat <<'EOF'

Done.

  1. pavucontrol -> Output Devices: the "DR70 - ..." sink is your DLNA
     renderer. Mark it as Fallback or move app streams to it.
  2. The DR70 must be in its DLNA input mode to receive the stream.
  3. ops:
       systemctl --user restart pa-dlna
       systemctl --user status pa-dlna
       journalctl --user -u pa-dlna -f
EOF