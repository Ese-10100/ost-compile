# ost-compile.sh

Merges a folder of audio tracks into one long M4A with crossfades and chapter markers. Built for Termux on Android, but it runs on any Linux shell with `ffmpeg`/`ffprobe`.

## Requirements

- bash
- ffmpeg (includes ffprobe)
- coreutils, findutils, awk, sed (standard on Termux)
- Optional: `termux-wake-lock` / `termux-wake-unlock` (keeps the job running in the background on Android)

On Termux: `pkg install ffmpeg`

## Usage

```bash
bash ost-compile.sh
```

Each run prints each stage to the terminal and writes the full log to `~/compile.log`. If something fails, the script prints the failing stage, the line number, the command that failed, the last ffmpeg command, a hint, and the log tail.

## Input files

The script takes any `.m4a` or `.mp3` files files in the folder set by `DIR`. It doesn't matter where they came from: a downloader, a ripper, or your own recordings. Only the filename matters, because it becomes the chapter title.

### Naming convention

Chapter titles come from filenames with these rules:

| In filename | In chapter title |
|---|---|
| `_s` | `'s` (possessive, e.g. `Korra_s_Journey` becomes `Korra's Journey`) |
| any other `_` | `'` (apostrophe, e.g. `Don_t_Stop` becomes `Don't Stop`) |
| `.m4a` extension | removed |

Because `_` is treated as an apostrophe, a filename can't contain a literal underscore. Keep that in mind when naming tracks.

Tracks are shuffled on each run. Tracks shorter than three times the crossfade length are skipped, and the log says which ones.

## Configuration

Set these as environment variables or edit the defaults at the top of the script:

```bash
DIR="${DIR:-$HOME/storage/music}"          # Folder containing your .m4a tracks
OUT="${OUT:-Test_OST_Compilation.m4a.m4a}"    # Output filename (written to the current folder)
XF="${XF:-2}"                              # Crossfade length in seconds
BATCH="${BATCH:-15}"                       # Tracks per batch; lower it if Android kills the job
TEST_N="${TEST_N:-0}"                      # Set above 0 to use only the first N tracks (quick test)
```

Example: a 5-track test run with a 3-second crossfade:

```bash
XF=3 TEST_N=5 bash ost-compile.sh
```

### Hardcoded values

These are fixed in the script. Edit them directly if your tracks differ:

- The output title tag: `Compiled Soundtrack`

## How it works

1. **Pre-flight:** checks tools, folder, free space, and track durations. Builds the chapter list before any encoding, so chapter bugs fail in seconds.
2. **Batches:** crossfades each batch of tracks into a lossless FLAC part.
3. **Join:** joins the parts and does a single AAC encode at 160 kbps.
4. **Chapters:** embeds chapter metadata without re-encoding.
5. **Verify:** compares the output length and chapter count against expectations.

Temporary files are kept in `~/korra_work` only if the script fails. On success they are deleted.

## Troubleshooting

| Error | Likely cause |
|---|---|
| Killed (exit 137) | Android ran out of memory. Lower `BATCH` to 8 and keep Termux in the foreground. |
| Command not found (127) | ffmpeg isn't installed. Run `pkg install ffmpeg`. |
| `moov atom not found` / `Invalid data` | A partial or corrupt download. Re-download the track named in the log. |
| `Permission denied` | Storage access. Run `termux-setup-storage`, then retry. |
| `No space left` | Free space, or lower `BATCH`. |
| Filter errors | Usually a track shorter than the crossfade length, or a bad input file. |

To debug, share the output of `tail -n 30 ~/compile.log`.

## License and audio

This script doesn't include any audio. Use only tracks you have the right to use. Don't redistribute the compiled output if the source audio is copyrighted.