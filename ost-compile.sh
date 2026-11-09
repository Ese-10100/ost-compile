#!/usr/bin/env bash
# OST compiler: batched crossfade + chapters. Run with: bash ost_compile.sh
set -Eeuo pipefail

DIR="${DIR:-$HOME/storage/music}"          # Your chosen music folder
OUT="${OUT:-Test_OST_Compilation.m4a}"     # Output file name
XF="${XF:-2}"                              # crossfade seconds
BATCH="${BATCH:-15}"                       # tracks per batch
TEST_N="${TEST_N:-0}"                      # >0 = use only the first N tracks (testing)
WORK="$HOME/korra_work"
LOG="$HOME/compile.log"
STAGE="startup"; LAST_CMD=""; CODEC=()
: > "$LOG"

log()   { printf '[%02d:%02d] %s\n' $((SECONDS/60)) $((SECONDS%60)) "$*" | tee -a "$LOG"; }
stage() { STAGE="$1"; LAST_CMD=""; printf '\n'; log "=== STAGE $1 ==="; }
fmt()   { awk -v s="$1" 'BEGIN{printf "%d:%02d:%02d", s/3600, (s%3600)/60, s%60}'; }

hint() {
  local code="$1" t
  t=$(tail -n 40 "$LOG" 2>/dev/null || true)
  case "$code" in
    137) echo "Killed by Android (memory). Lower BATCH (try 8) and keep Termux in the foreground."; return ;;
    127) echo "Command not found. Run: pkg install ffmpeg"; return ;;
  esac
  case "$t" in
    *"No space left"*) echo "Storage full. Free space or lower BATCH." ;;
    *"moov atom not found"*|*"Invalid data found"*) echo "Corrupt or partial download. Re-download the file named in the log." ;;
    *"Permission denied"*) echo "Storage permission. Run termux-setup-storage, then retry." ;;
    *"No such file"*) echo "Wrong path, or a file was renamed or moved mid-run." ;;
    *"Error initializing complex filters"*|*"Error reinitializing filters"*|*"Invalid argument"*)
      echo "Filter problem. Usually a track shorter than the ${XF}s crossfade, or a bad input." ;;
    *) echo "No known ffmpeg pattern. If no ffmpeg output follows the last '\$' line, it is a shell bug: read the 'shell command' line." ;;
  esac
}

on_error() {
  local code="$1" line="$2" cmd="$3" last
  trap - ERR
  last=$(tail -n 6 "$LOG")
  printf '\n[LOG TAIL]\n%s\n' "$last"
  {
    printf '\n[FAIL] stage: %s | line: %s | exit code: %s\n' "$STAGE" "$line" "$code"
    printf '[FAIL] shell command: %.200s\n' "$cmd"
    if [[ -n "$LAST_CMD" ]]; then printf '[FAIL] last ffmpeg command: %.300s\n' "$LAST_CMD"; fi
    printf '[HINT] %s\n' "$(hint "$code")"
    printf '[DEBUG] paste this to your LLM: tail -n 30 %s\n' "$LOG"
    printf '[NOTE] temp files kept in %s for inspection\n' "$WORK"
  } | tee -a "$LOG"
  exit "$code"
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

# Run ffmpeg quietly: output goes to the log, heartbeat on screen.
ff() {
  LAST_CMD="ffmpeg $*"
  printf '\n$ %s\n' "$LAST_CMD" >> "$LOG"
  ffmpeg -nostdin -y -hide_banner -v warning "$@" >> "$LOG" 2>&1 &
  local pid=$! s=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1; s=$((s+1))
    if (( s % 20 == 0 )); then printf '      ...still working (%ss)\n' "$s"; fi
  done
  wait "$pid"
}

# crossfade_to OUTFILE in1 in2 ...   (callers pass full paths; uses global CODEC)
crossfade_to() {
  local out="$1"; shift
  local cnt=$# inputs=() filter="" prev="[0:a]" f i
  for f in "$@"; do inputs+=(-i "$f"); done
  if (( cnt == 1 )); then
    ff "${inputs[@]}" "${CODEC[@]}" "$out"; return
  fi
  for ((i=1; i<cnt; i++)); do
    filter+="${prev}[$i:a]acrossfade=d=$XF:c1=tri:c2=tri[a$i];"
    prev="[a$i]"
  done
  ff "${inputs[@]}" -filter_complex "${filter%;}" -map "[a$((cnt-1))]" "${CODEC[@]}" "$out"
}

# ---------------- STAGE 1: pre-flight + chapter list ----------------
stage "1/5 Pre-flight checks + chapter list"
if ! command -v ffmpeg >/dev/null || ! command -v ffprobe >/dev/null; then
  log "ffmpeg/ffprobe missing. Install ffmpeg first."; exit 1
fi
[[ -d "$DIR" ]] || { log "Folder not found: $DIR"; exit 1; }
cd "$DIR"
if command -v termux-wake-lock >/dev/null; then termux-wake-lock || true; fi
mkdir -p "$WORK"; rm -rf "${WORK:?}"/*

mapfile -t all < <(find . -maxdepth 1 -type f \( -name '*.m4a' -o -name '*.mp3' \) ! -name "$OUT" -printf '%f\n' | shuf)
log "Found ${#all[@]} audio files in $DIR"
(( ${#all[@]} > 0 )) || { log "No audio files found."; exit 1; }
if (( TEST_N > 0 )); then all=("${all[@]:0:TEST_N}"); log "TEST MODE: first $TEST_N tracks only"; fi

files=(); dur=(); skipped=0
for f in "${all[@]}"; do
  d=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "./$f" 2>>"$LOG" || true)
  if [[ "$d" =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk -v d="$d" -v x="$XF" 'BEGIN{exit !(d>3*x)}'; then
    files+=("$f"); dur+=("$d")
  else
    log "  SKIP (unreadable or shorter than 3x crossfade): $f"; skipped=$((skipped+1))
  fi
done
n=${#files[@]}
(( n > 0 )) || { log "No usable tracks."; exit 1; }

expected=$(printf '%s\n' "${dur[@]}" | awk -v x="$XF" '{s+=$1} END{printf "%.1f", s-x*(NR-1)}')
need_mb=$(awk -v e="$expected" 'BEGIN{printf "%d", e/60*7+200}')
free_mb=$(df -Pk "$WORK" | awk 'NR==2{printf "%d", $4/1024}')
log "Usable tracks: $n (skipped $skipped) | expected length: $(fmt "$expected")"
log "Disk: need ~${need_mb}MB, free ${free_mb}MB"
(( free_mb >= need_mb )) || { log "Not enough free space."; exit 1; }

# Chapter file is built now so any bug here fails in seconds, not after the encode.
echo ";FFMETADATA1" > "$WORK/meta.txt"
q="'"; t=0
for ((i=0; i<n; i++)); do
  title="${files[i]%.*}"
  # title="${title% _ The Legend of Korra Soundtrack}"
  title="${title//_s/${q}s}"
  title="${title//_/$q}"
  title=$(printf '%s' "$title" | sed 's/[=;#\\]/\\&/g')
  read -r st en nt < <(awk -v t="$t" -v d="${dur[i]}" -v x="$XF" -v last=$((i==n-1)) \
    'BEGIN{e=(last? t+d : t+d-x); printf "%d %d %.3f\n", t*1000, e*1000, t+d-x}')
  printf '[CHAPTER]\nTIMEBASE=1/1000\nSTART=%s\nEND=%s\ntitle=%s\n\n' "$st" "$en" "$title" >> "$WORK/meta.txt"
  t=$nt
done
log "Built $n chapters. First: $(grep -m1 '^title=' "$WORK/meta.txt")"

# ---------------- STAGE 2: batches ----------------
stage "2/5 Crossfading in batches of $BATCH (lossless FLAC parts)"
CODEC=(-c:a flac -sample_fmt s16)
total_batches=$(( (n + BATCH - 1) / BATCH ))
p=0
for ((s=0; s<n; s+=BATCH)); do
  p=$((p+1))
  batch=(); for f in "${files[@]:s:BATCH}"; do batch+=("./$f"); done
  part="$WORK/part$(printf %02d "$p").flac"
  log "Batch $p/$total_batches: tracks $((s+1))-$((s+${#batch[@]})) of $n"
  crossfade_to "$part" "${batch[@]}"
  log "  batch $p done ($(du -h "$part" | cut -f1))"
done

# ---------------- STAGE 3: join + encode ----------------
stage "3/5 Joining parts + single AAC encode (160k)"
parts=("$WORK"/part*.flac)
CODEC=(-c:a aac -b:a 160k)
log "Joining ${#parts[@]} part(s)"
crossfade_to "$WORK/joined.m4a" "${parts[@]}"
log "  joined ($(du -h "$WORK/joined.m4a" | cut -f1))"

# ---------------- STAGE 4: embed chapters ----------------
stage "4/5 Embedding chapters (no re-encode)"
ff -i "$WORK/joined.m4a" -i "$WORK/meta.txt" -map 0:a -map_metadata 1 -map_chapters 1 \
   -metadata title="Compiled Soundtrack" -c copy "$WORK/final.m4a"
mv -f "$WORK/final.m4a" "$OUT"

# ---------------- STAGE 5: verify ----------------
stage "5/5 Verifying output"
got=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT")
chap=$(ffprobe -v error -show_chapters -of csv=p=0 "$OUT" | wc -l)
diff=$(awk -v a="$got" -v b="$expected" 'BEGIN{d=a-b; if(d<0)d=-d; printf "%.1f", d}')
log "Length: $(fmt "$got") (expected $(fmt "$expected"), off by ${diff}s)"
log "Chapters: $chap (expected $n)"
if awk -v d="$diff" 'BEGIN{exit !(d>3)}'; then log "WARNING: length is off by more than 3s. A crossfade may have misbehaved."; fi
(( chap == n )) || log "WARNING: chapter count does not match track count."

rm -rf "$WORK"
if command -v termux-wake-unlock >/dev/null; then termux-wake-unlock || true; fi
log "DONE: $DIR/$OUT ($(du -h "$OUT" | cut -f1)), $n tracks, $skipped skipped"