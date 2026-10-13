# YouTube Music (nicola.ytmusic)

Search, queue, and play YouTube Music from the Omarchy bar. No browser window:
audio plays through a background mpv, so it keeps going across shell reloads.

## Install

Needs Omarchy 4 with its Quickshell shell, plus `mpv`, `mpv-mpris`, `python`
and `wl-clipboard`:

```bash
sudo pacman -S --needed mpv mpv-mpris python wl-clipboard
omarchy plugin add https://github.com/n1c0la84/omarchy-ytmusic.git --enable
~/.config/omarchy/plugins/nicola.ytmusic/bin/ytm-setup
omarchy restart shell   # registers the IPC methods
```

## Pieces

- `Panel.qml` — bar icon + panel (now playing, search, queue, library).
- `bin/ytm-helper` — search / radio / library lookups via ytmusicapi, JSON out.
- `bin/ytm-mpv` — starts the audio-only mpv as the user unit
  `nicola-ytmusic-mpv`, IPC socket `$XDG_RUNTIME_DIR/nicola-ytmusic.sock`.
  mpv-mpris publishes it to MPRIS, so media keys and media widgets work.
- `bin/ytm-setup` — creates/updates the private venv
  `~/.local/share/nicola-ytmusic/venv` (current yt-dlp + ytmusicapi).
  **Re-run it when playback stops working**: YouTube breaks old yt-dlp
  versions (the distro one gets HTTP 403 on stream URLs).

State: `~/.local/state/nicola-ytmusic/state.json` (radio on/off, queue
metadata). Library login: `~/.local/share/nicola-ytmusic/browser.json`
(browser headers, mode 600; delete it to log out).

## Use

- Bar icon: left click opens the panel, right click play/pause, middle click next.
- Search + Enter. Click a song to play it (radio keeps going after it),
  right-click to play it next, `+` to add it to the queue.
- Queue tab: click to jump, right-click or `×` to remove.
- Library tab: import headers once (instructions in the panel), then playlists
  and liked songs; "Play all" / "Shuffle" on a playlist.

## IPC (for keybindings)

```
omarchy-shell nicola.ytmusic toggle|open|close
omarchy-shell nicola.ytmusic playPause|next|previous|stop
omarchy-shell nicola.ytmusic search "query"
omarchy-shell nicola.ytmusic playResult 0
omarchy-shell nicola.ytmusic nowPlaying
```

New IPC methods only register after `omarchy restart shell`.
