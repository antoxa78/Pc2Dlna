# Pc2Dlna

Forward this PC's audio (PipeWire/PulseAudio) to a **DLNA renderer** on the LAN —
setup for the **CelMusper DR70** (CelCast) which the machine runs in DLNA mode.

Built on `pa-dlna` (Debian) + a handful of targeted fixes that make it
reliable with consumer renderers like the DR70.

## Layout

```
Pc2Dlna/
├── install.sh          # one-shot bootstrap (idempotent)
├── files/
│   ├── pa-dlna.conf                     # lossless-first encoder selection (FLAC primary)
│   ├── pa-dlna.service                  # user systemd unit (autostart, -m 15 msearch)
│   └── pipewire-bitperfect-44100.conf   # PipeWire graph pinned to 44.1 kHz
└── patches/
    ├── upnp.py.patch                    # foreign-namespace SCPD, no blacklisting
    ├── network.py.patch                 # HTTP/1.1 + SSDP log noise
    ├── http_server.py.patch             # keep pipeline warm across drops
    ├── pulseaudio.py.patch              # null-sink at encoder rate, reconnect handling
    └── pa_dlna.py.patch                 # survive SOAP faults, force-fresh streams
```

## Install

```sh
./install.sh            # detects the default-route NIC; or pass one:
./install.sh wlp3s0     # e.g. for the wifi on the LMDE laptop
```

What it does:

1. `apt install pa-dlna pavucontrol` (if missing).
2. Copies the *pristine* system `pa_dlna` package into the Python **user site**
   and applies `patches/*.patch` to it. A stamp file records the pa-dlna version
   and the patch checksum: re-runs are no-ops while both are unchanged, and
   after an `apt upgrade` of pa-dlna (or a patch edit) the copy is rebuilt from
   the new pristine package (the old one is moved aside as
   `pa_dlna.disabled-<date>`). A patch that no longer applies aborts the install
   with an error instead of leaving a half-patched copy.
   If the `pc2dlna` `.deb` is installed, no user-site copy is made (it would
   shadow the `.deb`); an existing one is moved aside.
3. Writes `~/.config/pa-dlna/pa-dlna.conf` with lossless-first encoding.
4. Writes the PipeWire drop-in `~/.config/pipewire/pipewire.conf.d/40-bitperfect-44100.conf`
   and **restarts PipeWire** (audio is interrupted for a few seconds) — only when
   the file is new or changed. `PC2DLNA_NO_PIPEWIRE=1 ./install.sh` skips this
   step entirely.
5. Installs + enables `~/.config/systemd/user/pa-dlna.service`. The network
   interface is fixed in the unit (`-n <nic>`); if none is detected the option is
   omitted and pa-dlna uses all interfaces. Re-run `install.sh` if the interface
   changes (e.g. wifi → ethernet).

### Debian package

`./build_deb.sh` builds `build/Pc2Dlna_<version>_all.deb` from the *pristine*
system `pa_dlna` + `patches/` (it never reads `~/.local`). The package depends
on the exact pa-dlna version and the Python minor version it was built with,
so rebuild it after upgrading either. It installs only the patched modules,
the user unit and examples; the PipeWire drop-in and `pa-dlna.conf` are in
`/usr/share/doc/pc2dlna/examples/`. A user-site copy from an older
`install.sh` run shadows the package: `postinst` warns about it, and
`install.sh` moves it aside.

## Usage

- `pavucontrol` → *Output Devices*: the `DR70 - 85f7…` sink *is* the renderer.
  Mark it **Fallback**, or move individual playback apps to it (like Apple Music,
  web players). It is a real PulseAudio sink, so anything routable works.
- The DR70 must be set to its **DLNA input mode** or it answers every UPnP action
  with HTTP 501 and nothing plays.
- The PipeWire graph is pinned to 44.1 kHz (see *Audio fidelity* below), and the
  stream is sent as 44.1 kHz FLAC.

## Audio fidelity / bit-perfect

**Verdict: CD-rate (44.1 kHz) sources are routed *bit-perfect* — zero
resampling end-to-end — and the DAC now displays the true source rate.**

The chain on this machine:

```
radio/player app (44.1k) --PipeWire graph (float32 44.1k)--> null-sink
    -> monitor -> parec (s16le 44.1k) -> ffmpeg (FLAC 44.1k) -> DR70
```

Three things make this possible:

- **PipeWire graph clock is pinned to 44.1 kHz** via
  `~/.config/pipewire/pipewire.conf.d/40-bitperfect-44100.conf`
  (`default.clock.rate = 44100`, `allowed-rates = [ 44100 48000 ]`). The
  stock default runs the whole audio graph at 48 kHz, which resampled every
  CD source to 48 kHz and made the DR70 display "48" — the bug this fixes.
- **The pa-dlna null-sink is created at the streamed encoder rate**
  (`patches/pulseaudio.py.patch`): by default PulseAudio/pipewire-pulse
  creates null-sinks at 48 kHz regardless of the graph clock, so the sink is
  now created with `rate = 44100` taken from the configured encoder.
- **The encoders are configured at `rate = 44100`** (`files/pa-dlna.conf`),
  so parec/ffmpeg capture the monitor at exactly the graph rate. No second
  resample.
- The only conversion left is the float32→s16 conversion of the monitor
  samples. It is lossless for 16-bit content **only at 100% volume with a
  single stream**: any gain or mixing of several streams changes the samples.

Caveats:

- **48 kHz sources (some internet radio, most video) are resampled to 44.1 kHz**
  by the graph. (`allowed-rates` also lists 48000, so PipeWire may switch the
  graph to 48 kHz for a stream that forces that rate; the null-sink stays
  at 44.1 kHz and the monitor is then resampled.) For a music player this is usually acceptable (48 kHz content is
  typically lossy radio, not lossless files).
- True passthrough of a native 48 kHz lossless file would require running the
  graph at 48 kHz for that session instead.

## Operations

```sh
systemctl --user restart pa-dlna     # restart the daemon
systemctl --user status pa-dlna
journalctl --user -u pa-dlna -f      # watch log
pactl set-default-sink "CelCast-uuid:85f70b2d-3c72-501f-a172-07bbc058d793"
```

## The fixes (why)

1. **Foreign-namespace SCPD** (`upnp.py`): the DR70 carries a Tencent `QPlay`
   service whose XML isn't `urn:schemas-upnp-org:`; stock pa-dlna aborts the whole
   device on it. Patch: skip such SCPDs with a warning.
2. **Permanent blacklisting** (`upnp.py`): after any UPnP error pa-dlna marked the
   device `_faulty_devices` *forever* — a transient DR70 hiccup killed streaming
   until a manual restart. Patch: close and re-create on next discovery
   (msearch every 15s via `-m 15`).
3. **HTTP/1.0 client** (`network.py`): pa-dlna sent every request as HTTP/1.0;
   HTTP/1.1-only devices (e.g. tegra/NVIDIA Shield at 192.168.31.194) respond with
   an empty header → endless error/discover spin. Patch: HTTP/1.1 with
   `Connection: close`.
4. **Stream teardown on every drop** (`http_server.py`): when the renderer closed
   the HTTP stream, pa-dlna killed the whole pipeline (parec + encoder) and
   unloaded/reloaded the null-sink; the DR70 re-pulls seconds later, so each drop
   cost real dead air. Patch: on a connection drop, keep the pipeline warm for
   `STREAM_LINGER_SECS` (15s); a re-pull within that window attaches to the
   running pipeline seamlessly. This is what prevents the "music stops playing"
   gaps on the DR70.
5. **SSDP log spam** (`network.py`): home devices multicast incomplete SSDP
   announces (the DR70 sends a proprietary `ssdp:all` notify without
   LOCATION/USN every 15s). Upstream warned on each, flooding the journal.
   Patch: structurally-incomplete announces now log at debug level; only truly
   malformed headers warn.
6. **Null-sink created at 48 kHz** (`pulseaudio.py`): pa-dlna loaded
   `module-null-sink` with no `rate=`, so pipewire-pulse defaulted the sink
   to 48 kHz — the DAC displayed 48 kHz no matter the source. Patch: create
   the sink at the configured encoder rate (44.1 kHz), so the monitor and the
   stream run at the source-native rate. The sink properties are passed as one
   quoted `sink_properties="device.description='…' session.suspend-timeout-seconds=0"`
   value, which real PulseAudio also accepts.
7. **Restart never (re)starts the stream** (`pa_dlna.py` + `pulseaudio.py`):
   two compounding bugs meant a drop kept the DR70 silent forever. First,
   `GetTransportInfo`/SOAP 501s tore the renderer down (unloading the
   null-sink) — transient, but every blip cost minutes. Second, renderers
   like the DR70 keep reporting `PLAYING` even after their transport is
   Stopped, so on reconnect pa-dlna walked the *SetNextAVTransportURI*
   (track-change) path instead of `SetAVTransportURI`+`Play`, and the DR70
   never pulled the stream again. Patch: SOAP faults inside the event loop
   are logged without tearing anything down, and the lost pulse event is
   replayed from the sink's current state after a short back-off, and a MetaData
   action (re)starts a *fresh* `SetAVTransportURI`+`Play` whenever the HTTP
   stream is not actually flowing — regardless of what the renderer claims.
   Same-index sink-input reconnects are also no longer swallowed as "previous
   sink-input" events.
8. **`parec` can end on its own, leaving dead air** (`http_server.py` +
   `pulseaudio.py`): the recorder's pulse stream may be ended server-side
   (e.g. the sink/monitor getting suspended when the source briefly goes
   silent); pa-dlna then tore down the pipeline and a stale `is_playing`
   state kept the next metadata action on the track-change path, so the DR70
   never pulled again. Patch: the null-sink and its monitor are created with
   `session.suspend-timeout-seconds=0` so they are never suspended, and if
   `parec` still ends unexpectedly the stream is restarted automatically
   with a fresh `SetAVTransportURI`+`Play`. Retries are bounded
   (`PAREC_RESTART_MAX` = 3); the budget is refilled only after the restarted
   stream has run for 60 s without parec dying again, so a flapping stream
   cannot restart forever.
9. **One `remove` event stopped playback for everyone** (`pa_dlna.py`): the
   monitor carries the mix of *all* sink-inputs on the null-sink, but
   `maybe_stop` only looked at the single tracked sink-input — so when that
   app's stream was removed while others were still playing, pa-dlna tore
   the session down and Stopped the DR70 (left permanently silent, since no
   further pulse event arrives for the still-playing stream). Patch:
   `maybe_stop` now re-queries the sink for any remaining sink-input; if one
   is still routed, it adopts it and keeps streaming (restarting the pull
   only if the HTTP stream had already ended).
10. **Source-app pause mapped onto the renderer transport** (`pa_dlna.py`):
   when the source app is paused, PipeWire marks the sink-input as corked
   (`pulse.corked` proplist) and feeds digital silence, so the null-sink
   monitor keeps emitting zeros and pa-dlna streamed that silence to the
   renderer **forever** — the DR70 kept "playing", so pause felt like it took
   tens of seconds (or never happened at all). Patch: the `pulse.corked`
   state is tracked from the sink-input 'change' events; a cork sends a SOAP
   `Pause` to the AVTransport (the DR70 freezes instantly — also verified as
   `PAUSED_PLAYBACK` with its position counter frozen), an uncork resumes
   with `Play`. A transport stranded in `PAUSED_PLAYBACK` by a source app
   that reconnects its stream mid-pause (rust-radio does this) or by a
   renderer self-pause on underrun is restarted with a fresh
   `SetAVTransportURI`+`Play` — unless the source is still corked, in which
   case the pause is preserved for the cork-resume path.
11. **Adopt-and-reconcile in `maybe_stop`** (`pa_dlna.py`): when a source
   stream is reconnected while the renderer is paused, the resume 'change'
   event arrives with a *new* sink-input index, so the cork-resume path
   (which matches indices) could silently skip it and the renderer stayed
   paused while the user was playing — "no sound". On adoption `maybe_stop`
   now re-queries the live transport state and brings it in line with the
   adopted stream: `Play` if the source is playing but the transport is
   `PAUSED_PLAYBACK`, `Pause` if the source is still corked but the renderer
   plays on (silence streaming), and a full `SetAVTransportURI`+`Play`
   restart if the pull had already ended.
12. **Auto-restore after a renderer drop** (`http_server.py`): the CelMus
    DR70 sometimes aborts the HTTP pull on its own (connection reset) and
    does not come back. With no pulse event following, nothing re-established
    the stream: the renderer went silent even though the source kept playing
    — "no sound" until a manual restart. `StreamSessions._linger()`, which
    already kept the pipeline warm for 15s, now queues a restart (via the
    existing `schedule_restart()`, run as a detached task *before* the
    teardown so it cannot be cancelled) and the stream is re-issued with a
    fresh `SetAVTransportURI`+`Play` whenever a sink-input is still routed
    and the source is not corked. Verified: a simulated renderer drop
    (`Stop`) is recovered automatically in ~17s.
13. **Resilient long-pause resume + drop recovery cadence** (`pa_dlna.py`,
    `http_server.py`): after ~10–12 s of pause the DR70 silently self-stops
    (transport `STOPPED`, position reset) and an uncork then issues a bare
    `Play` that targets a stopped transport — the device never responds, so
    the renderer stays silent. The cork-resume path now always re-establishes
    a fresh stream (`is_playing=False` then `SetAVTransportURI`+`Play`) like
    the stranded-transport path in #10, so a mid-self-stop resume restarts
    cleanly. During the recovery, a drop is *not* retried on a short (~2 s)
    timer: while the DR70 is busy tearing down it rejects every pull, and an
    ~8 s retry cadence kept it wedged in an endless play-6s/drop loop
    (verified in the journal). The single `_linger()` restart after the 15 s
    settle window is what the renderer actually accepts, so that is the one
    retry per drop — worst case a long-pause resume gets sound back in ~17 s
    (`Stop`→15 s linger→restart), typically the first `SetAVTransportURI`
    right after the uncork is accepted.
14. **Pause keepalive, pause/play verification, and a track-reader race**
    (`pa_dlna.py`): three further hardening fixes against the DR70's flakiness
    (it self-reboots and drops individual SOAPs throughout the day). (a) While
    the source is paused, a background task polls `GetTransportInfo` every 4 s;
    this resets the device's ~10 s idle watchdog so it stays in
    `PAUSED_PLAYBACK` instead of self-stopping, and the resume is then instant
    (verified live: the poll held the DR70 paused for 36 s and `Play` resumed
    immediately) — previously a >10 s pause meant a ~25–30 s settle before
    sound returned. (b) `Pause` and `Play` are each verified with a
    `GetTransportInfo` read and retried once if the device silently dropped
    them (observed during mid track-change flapping). (c) `set_avtransporturi`
    now stops any still-running track first (mirroring
    `set_nextavtransporturi`); a forced restart on resume used to issue
    `SetAVTransportURI` while the warm pipeline's previous track was still
    reading the shared encoder stream, raising
    `readexactly() called while another coroutine is already waiting` (14
    occurrences) and killing the stream silently.

## Troubleshooting

- **No sink appears**: DR70 in DLNA mode? `journalctl --user -u pa-dlna -f` shows
  `Disable the ... (re-enabling on next discovery)` blips — normal and
  self-healing.
- **Constant `missing "LOCATION"` warnings**: that's the DR70's proprietary SSDP
  announce (`CelMusperOS`, `X-CUSTOM-KEY`), harmless noise.
- **Choppy streams**: check DR70 WiFi/UPnP stability; a drop now only costs a few
  seconds before the renderer reconnects.
- After `apt upgrade pa-dlna`, re-run `./install.sh` (or rebuild the `.deb`): the
  patched copy is rebuilt from the new pristine package. Until then the old copy
  keeps shadowing it.

## Renderers seen on this LAN

| IP            | Device            | Role                       |
|---------------|-------------------|----------------------------|
| 192.168.31.245 | CelMusper DR70  | DLNA renderer (CelCast)   |
| 192.168.31.194 | NVIDIA tegra     | Chromecast/DIAL only — ignore |