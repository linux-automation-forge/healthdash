#!/usr/bin/env bash
# healthdash.sh — Terminal System Health Dashboard (bash 4+, Linux/WSL2)
# v1.0.0 — CPU / RAM / swap / disks / network rates / top procs / failed logins
# USAGE: ./healthdash.sh [-i SEC] [-t N] [-1] [--no-color] [--gen-files] [-h|-V]
# Live mode: press q to quit. One-shot: -1 (cron/screenshot friendly).
# SAFE BY DESIGN: read-only monitoring of your own machine. Sends nothing.
set -Eeuo pipefail
IFS=$'\n\t'
export LC_ALL=C

SCRIPT_NAME="$(basename -- "${BASH_SOURCE[0]}")"
VERSION="1.0.0"

# ==================== USER-CONFIGURABLE DEFAULTS (edit freely) ==============
INTERVAL=2            # refresh seconds              (-i N)
TOP_N=5               # processes per TOP panel      (-t N)
ONE_SHOT=0            # 1 = render once and exit     (-1)
USE_COLOR=1           # --no-color / NO_COLOR / piped disables
DISK_ROWS=4           # disks shown (worst first)
DISK_EXCLUDES="tmpfs devtmpfs squashfs iso9660 overlay udf ramfs"
NET_IFACES_MAX=3      # busiest interfaces shown
CPU_WARN=60; CPU_CRIT=85
MEM_WARN=70; MEM_CRIT=90

if [[ ! -t 1 || -n "${NO_COLOR:-}" ]]; then USE_COLOR=0; fi
R=$'\033[0m'; B=$'\033[1m'; DIM=$'\033[2m'
GRN=$'\033[1;32m'; YLW=$'\033[1;33m'; RED=$'\033[1;31m'
CYN=$'\033[1;36m'; BLU=$'\033[1;34m'; MAG=$'\033[1;35m'

c()   { if [[ "$USE_COLOR" -eq 1 ]]; then printf '%s' "$1"; fi; }
lbl() { c "$BLU"; printf '%-5s' "$1"; c "$R"; }
sect() { c "$MAG"; printf '── %s ' "$1"; c "$R"
         printf '─%.0s' $(seq 1 "${2:-60}"); printf '\n'; }
die() { printf '%sERROR:%s %s\n' "$RED" "$R" "$2" >&2; exit "$1"; }

# ==================== HELPERS ===============================================
color_for_pct() {
    if   (( "$1" >= 85 )); then printf '%s' "$RED"
    elif (( "$1" >= 60 )); then printf '%s' "$YLW"
    else                        printf '%s' "$GRN"; fi
}
bar() { # bar PCT [WIDTH] → colored "[#####-----]"
    local pct="$1" w="${2:-20}" fill col
    (( pct < 0 ))   && pct=0
    (( pct > 100 )) && pct=100
    fill=$(( pct * w / 100 )); (( pct > 0 && fill == 0 )) && fill=1
    col="$(color_for_pct "$pct")"
    printf '['; c "$col"; printf '%*s' "$fill" '' | tr ' ' '#'
    c "$R"; printf '%*s' $(( w - fill )) '' | tr ' ' '-'; printf ']'
}
human() { awk -v b="${1:-0}" 'BEGIN{
    split("K M G T P",A," "); i=0
    while (b>=1024 && i<5){b/=1024;i++}
    printf "%.1f%s", b, (i==0?"B":A[i])}'; }

# ==================== COLLECTORS ============================================
PREV_CPU=(); HAVE_PREV_CPU=0; CPU_PCT=0
cpu_load_pct() {
    local -a cur
    IFS=' ' read -r -a cur <<< "$(head -n1 /proc/stat | cut -d' ' -f2-)"
    if [[ "$HAVE_PREV_CPU" -eq 1 ]]; then
        local dtotal=0 didle=0 i v
        for i in 0 1 2 3 4 5 6 7; do
            v=$(( ${cur[$i]:-0} - ${PREV_CPU[$i]:-0} ))
            dtotal=$(( dtotal + v ))
            if (( i == 3 || i == 4 )); then didle=$(( didle + v )); fi
        done
        if (( dtotal > 0 )); then CPU_PCT=$(( 100 * (dtotal - didle) / dtotal ))
        else CPU_PCT=0; fi
    else
        CPU_PCT=0
    fi
    PREV_CPU=("${cur[@]}"); HAVE_PREV_CPU=1
}

M_TOTAL=0; M_AVAIL=0; M_USED=0; M_PCT=0; SW_TOTAL=0; SW_FREE=0; SW_USED=0; SW_PCT=0
mem_info() {
    local k v
    while IFS=' ' read -r k v _; do
        case "$k" in
            MemTotal:)     M_TOTAL="$v" ;;
            MemAvailable:) M_AVAIL="$v" ;;
            SwapTotal:)    SW_TOTAL="$v" ;;
            SwapFree:)     SW_FREE="$v" ;;
        esac
    done < /proc/meminfo
    M_USED=$(( M_TOTAL - M_AVAIL ))
    if (( M_TOTAL > 0 )); then M_PCT=$(( 100 * M_USED / M_TOTAL )); else M_PCT=0; fi
    SW_USED=$(( SW_TOTAL - SW_FREE ))
    if (( SW_TOTAL > 0 )); then SW_PCT=$(( 100 * SW_USED / SW_TOTAL )); else SW_PCT=0; fi
}

disk_rows() { # prints "pct used_kb avail_kb mount" worst-first, max DISK_ROWS
    local -a types=() args=(); local t
    IFS=' ' read -r -a types <<< "$DISK_EXCLUDES"
    for t in "${types[@]}"; do args+=(-x "$t"); done
    df -P "${args[@]}" 2>/dev/null | tail -n +2 \
        | awk '{gsub(/%/,"",$5); printf "%d %s %s %s\n",$5,$3,$4,$6}' \
        | sort -rn | head -n "$DISK_ROWS"
}

declare -A PREV_RX=() PREV_TX=() RXB=() TXB=()
NET_LINES=(); HAVE_PREV_NET=0; NET_FIRST=1
net_panel_data() {
    local line ifc rest rx tx
    RXB=(); TXB=()
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        [[ "$line" == *:* ]] || continue
        ifc="${line%%:*}"; rest="${line#*:}"
        [[ -z "$ifc" || "$ifc" == "lo" ]] && continue
        local -a v; IFS=' ' read -r -a v <<< "$rest"
        rx="${v[0]:-0}"; tx="${v[8]:-0}"
        RXB["$ifc"]="$rx"; TXB["$ifc"]="$tx"
    done < /proc/net/dev
    NET_LINES=()
    if [[ "$HAVE_PREV_NET" -eq 1 ]]; then
        NET_FIRST=0
        local ifc dr dt
        for ifc in "${!RXB[@]}"; do
            dr=$(( RXB[$ifc] - ${PREV_RX[$ifc]:-0} ))
            dt=$(( TXB[$ifc] - ${PREV_TX[$ifc]:-0} ))
            (( dr < 0 )) && dr=0
            (( dt < 0 )) && dt=0
            NET_LINES+=("$ifc $dr $dt ${RXB[$ifc]} ${TXB[$ifc]}")
        done
    fi
    PREV_RX=(); PREV_TX=()
    for ifc in "${!RXB[@]}"; do
        PREV_RX[$ifc]="${RXB[$ifc]}"; PREV_TX[$ifc]="${TXB[$ifc]}"
    done
    HAVE_PREV_NET=1
}

FAILED_LOGINS="n/a"; AUTH_SRC="no readable auth source"; LISTEN_N="0"
security_stats() {
    local n
    if command -v lastb > /dev/null 2>&1; then
        n="$(lastb 2>/dev/null | grep -c . || true)"
        if [[ "${n:-0}" -gt 1 ]]; then
            FAILED_LOGINS="$(( n - 1 ))"; AUTH_SRC="btmp (lastb)"
        fi
    fi
    if [[ "$FAILED_LOGINS" == "n/a" && -r /var/log/auth.log ]]; then
        n="$(grep -ac 'Failed password' /var/log/auth.log 2>/dev/null || true)"
        if [[ "${n:-0}" -gt 0 ]]; then FAILED_LOGINS="$n"; AUTH_SRC="auth.log"; fi
    fi
    LISTEN_N="$(ss -H -tuln 2>/dev/null | grep -c . || true)"
    LISTEN_N="${LISTEN_N:-0}"
}

# ==================== PANELS ================================================
draw_header() {
    local host kern up_s load now upt
    host="$(uname -n)"; kern="$(uname -r)"
    up_s="$(cut -d. -f1 /proc/uptime)"
    load="$(cut -d' ' -f1-3 /proc/loadavg)"
    now="$(date '+%a %H:%M:%S')"
    local d=$(( up_s / 86400 )) h=$(( (up_s % 86400) / 3600 )) m=$(( (up_s % 3600) / 60 ))
    upt="${d}d ${h}h ${m}m"
    c "$B$CYN"; printf ' HEALTHDASH'; c "$R"; c "$DIM"; printf ' ◆ '; c "$R"
    c "$B"; printf '%s' "$host"; c "$R"; c "$DIM"; printf ' ◆ '; c "$R"
    printf 'kernel %s ◆ up %s ◆ load %s ◆ %s\n' "$kern" "$upt" "$load" "$now"
}
draw_cpu() {
    lbl 'CPU'; bar "$CPU_PCT" 22; printf ' %3d%%   ' "$CPU_PCT"
    c "$DIM"; printf 'load %s\n' "$(cut -d' ' -f1-3 /proc/loadavg)"; c "$R"
}
draw_mem() {
    lbl 'MEM'; bar "$M_PCT" 22; printf ' %3d%%  ' "$M_PCT"
    printf '%s / %s used   ' "$(human $(( M_USED * 1024 )))" "$(human $(( M_TOTAL * 1024 )))"
    if (( SW_TOTAL > 0 )); then
        printf 'SWAP '; bar "$SW_PCT" 10
        printf ' %2d%% (%s/%s)' "$SW_PCT" \
            "$(human $(( SW_USED * 1024 )))" "$(human $(( SW_TOTAL * 1024 )))"
    else
        printf 'SWAP none'
    fi
    printf '\n'
}
draw_disks() {
    sect 'DISKS' 64
    local pct used avail mnt
    while IFS=' ' read -r pct used avail mnt; do
        [[ -z "${pct:-}" ]] && continue
        printf '  %-14s' "${mnt:0:14}"
        bar "$pct" 20; printf ' %3d%%  ' "$pct"
        printf '%s used / %s free\n' \
            "$(human $(( used * 1024 )))" "$(human $(( avail * 1024 )))"
    done < <(disk_rows)
}
draw_net() {
    sect 'NETWORK (rates per refresh)' 64
    if [[ "$NET_FIRST" -eq 1 ]]; then
        c "$DIM"; printf '  (first sample — rates appear next refresh)\n'; c "$R"
        return 0
    fi
    local ifc dr dt rx tx n=0
    while IFS=' ' read -r ifc dr dt rx tx; do
        [[ -z "${ifc:-}" ]] && continue
        printf '  %-8s ↓ %8s/s  ↑ %8s/s   total ↓ %-7s ↑ %-7s\n' \
            "$ifc" "$(human "$dr")" "$(human "$dt")" \
            "$(human "$rx")" "$(human "$tx")"
        n=$(( n + 1 ))
        if (( n >= NET_IFACES_MAX )); then break; fi
    done < <(printf '%s\n' "${NET_LINES[@]}" \
        | awk '{print $2+$3, $0}' | sort -rn | head -n "$NET_IFACES_MAX" | cut -d' ' -f2-)
    return 0
}
draw_procs() {
    sect 'TOP PROCESSES' 64
    c "$B"; printf '  by CPU:\n'; c "$R"
    ps -eo pcpu,pmem,comm --sort=-pcpu 2>/dev/null | tail -n +2 | head -n "$TOP_N" \
        | awk '{printf "   %5.1f%%  %s\n",$1,$3}'
    c "$B"; printf '  by MEM:\n'; c "$R"
    ps -eo pcpu,pmem,comm --sort=-pmem 2>/dev/null | tail -n +2 | head -n "$TOP_N" \
        | awk '{printf "   %5.1f%%  %s\n",$2,$3}'
}
draw_sec() {
    sect 'SECURITY' 64
    printf '  failed logins: %s  (%s)\n' "$FAILED_LOGINS" "$AUTH_SRC"
    printf '  listening ports: %s\n' "$LISTEN_N"
}
draw_hint() {
    c "$DIM"; printf " q quit · refresh ${INTERVAL}s · -i N interval · -1 one-shot · --help\n"; c "$R"
}

render_frame() {
    cpu_load_pct; mem_info; net_panel_data; security_stats
    if [[ -t 1 ]]; then printf '\033[H'; fi
    draw_header; draw_cpu; draw_mem; draw_disks; draw_net; draw_procs; draw_sec; draw_hint
    if [[ -t 1 ]]; then printf '\033[J'; fi
    return 0
}

# ==================== RUN MODES / TRAPS =====================================
ALT=0
cleanup() { if [[ "$ALT" -eq 1 ]]; then printf '\033[?1049l\033[?25h'; ALT=0; fi; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

run_live() {
    if [[ -t 1 ]]; then printf '\033[?1049h\033[?25l'; ALT=1; clear; fi
    local key=""
    while true; do
        render_frame
        if [[ -t 0 ]]; then
            key=""
            IFS= read -r -s -t "$INTERVAL" -n 1 key || true
            if [[ "$key" == "q" || "$key" == "Q" ]]; then break; fi
        else
            sleep "$INTERVAL"
        fi
    done
    return 0
}

# ==================== CLI ====================================================
usage() {
    cat <<'HDEOF'
healthdash.sh — terminal system health dashboard (CPU/RAM/disks/net/procs/logins)

USAGE
  ./healthdash.sh [options]

OPTIONS
  -i SEC        refresh interval in seconds      (default 2)
  -t N          processes per TOP panel          (default 5)
  -1, --once    render one frame and exit (cron/screenshot friendly)
  --no-color    disable ANSI colors (auto-off when piped; NO_COLOR respected)
  --gen-files   write README.md LICENSE requirements.txt .gitignore (for GitHub)
  -h, --help    this help
  -V, --version print version

LIVE MODE: press q to quit. Works on Linux + WSL2.
SELF-TEST: HEALTHDASH_SELFTEST=1 bash healthdash.sh   (offline, no root needed)

All defaults are editable in the USER-CONFIGURABLE DEFAULTS block at the top.
HDEOF
}
parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            -i) [[ -n "${2:-}" && "$2" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
                    || die 2 "-i needs seconds (e.g. -i 2)"
                INTERVAL="$2"; shift 2 ;;
            -t) [[ -n "${2:-}" && "$2" =~ ^[0-9]+$ ]] \
                    || die 2 "-t needs a number (e.g. -t 8)"
                TOP_N="$2"; shift 2 ;;
            -1|--once)   ONE_SHOT=1; shift ;;
            --no-color)  USE_COLOR=0; shift ;;
            --gen-files) gen_repo_files; exit 0 ;;
            -h|--help)   usage; exit 0 ;;
            -V|--version) printf '%s v%s\n' "$SCRIPT_NAME" "$VERSION"; exit 0 ;;
            *) die 2 "unknown option '$1' — try --help" ;;
        esac
    done
}

# ==================== SELF-TEST (offline, safe) =============================
self_test() {
    local pass=0 fail=0 out
    ok()  { printf '  %sPASS%s %s\n' "$GRN" "$R" "$1"; pass=$((pass+1)); }
    bad() { printf '  %sFAIL%s %s\n' "$RED" "$R" "$1"; fail=$((fail+1)); }
    printf '%sHEALTHDASH SELF-TEST (offline, read-only)%s\n' "$CYN" "$R"

    mem_info
    if [[ "${M_TOTAL:-}" =~ ^[0-9]+$ ]] && (( M_TOTAL > 0 )); then
        ok "/proc/meminfo parse (total ${M_TOTAL} KB)"
    else bad "/proc/meminfo parse"; fi

    local -a cf; IFS=' ' read -r -a cf <<< "$(head -n1 /proc/stat)"
    if (( ${#cf[@]} >= 8 )); then
        ok "/proc/stat cpu fields (${#cf[@]})"
    else bad "/proc/stat cpu fields"; fi

    USE_COLOR=0
    out="$(bar 50 10)"
    if [[ ${#out} -eq 12 && "$out" == *'#####'* && "$out" == *'-----'* ]]; then
        ok "bar render (50%% → $out)"
    else bad "bar render ('$out')"; fi

    out="$(human 1536)"
    if [[ "$out" == "1.5K" ]]; then ok "human size (1536 → $out)"
    else bad "human size ('$out')"; fi

    out="$(disk_rows | wc -l)"
    if (( out <= DISK_ROWS )); then ok "disk rows ≤ $DISK_ROWS (got $out)"
    else bad "disk rows (got $out)"; fi

    net_panel_data
    if [[ "$NET_FIRST" -eq 1 || "${#NET_LINES[@]}" -gt 0 ]]; then
        ok "network snapshot parse"
    else bad "network snapshot parse"; fi

    security_stats
    if [[ "$LISTEN_N" =~ ^[0-9]+$ ]]; then
        ok "listening ports count ($LISTEN_N)"
    else bad "listening ports count"; fi

    if bash "$SCRIPT_NAME" -1 > /dev/null 2>&1; then ok "one-shot render exits 0"
    else bad "one-shot render"; fi

    printf '%sRESULT: pass=%d fail=%d%s\n' "$CYN" "$pass" "$fail" "$R"
    if (( fail > 0 )); then exit 1; fi
    printf '%sSELF-TEST OK%s\n' "$GRN" "$R"
}

# ==================== --gen-files (GitHub repo spawner) =====================
gen_repo_files() {
    [[ -e README.md ]] || { cat > README.md <<'HDR1'
# healthdash

One bash script → a live terminal dashboard for your own machine: CPU, RAM,
swap, disks, per-interface network rates, top processes, and a quick security
line (failed logins + listening ports). Press q to quit. `-1` renders a single
frame (perfect for cron or screenshots).

## quick start

    git clone https://github.com/YOURNAME/healthdash.git
    cd healthdash
    chmod +x healthdash.sh
    ./healthdash.sh

## why I built it

htop is great, but I wanted ONE screen answering MY questions: am I about to
run out of disk, what is eating CPU right now, is anything hammering my ssh?

## notes

- Linux + WSL2. bash 4+. Read-only — never changes anything on your system.
- Failed-login panel uses lastb/auth.log when readable; shows n/a otherwise
  (normal on WSL).
- Colors auto-disable when piped (cron-friendly). NO_COLOR is respected.
- Self-test: `HEALTHDASH_SELFTEST=1 bash healthdash.sh`
- Thresholds, interval, top-N: edit the DEFAULTS block at the top of the
  script, or pass flags (`-i 1`, `-t 10`).

MIT licensed. No warranty.
HDR1
    printf '  [ok] README.md\n'; }
    [[ -e LICENSE ]] || { cat > LICENSE <<'HDR2'
MIT License

Copyright (c) 2025 YOUR NAME HERE

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
HDR2
    printf '  [ok] LICENSE (add your name!)\n'; }
    [[ -e requirements.txt ]] || { cat > requirements.txt <<'HDR3'
# Everything is either built-in or preinstalled on normal Linux/WSL.

bash          (4.0+)   required
coreutils     (df, seq, date, cut, sort, head, awk)  required
procps        (ps)     required
iproute2      (ss)     optional — listening-ports count
util-linux    (lastb)  optional — failed-logins panel
HDR3
    printf '  [ok] requirements.txt\n'; }
    [[ -e .gitignore ]] || { cat > .gitignore <<'HDR4'
*.log
.DS_Store
HDR4
    printf '  [ok] .gitignore\n'; }
    printf '\nDone. Edit LICENSE (your name) + README clone URL, then upload.\n'
}

# ==================== ENTRY POINT ===========================================
if [[ "${HEALTHDASH_SELFTEST:-0}" == "1" ]]; then
    self_test
else
    parse_args "$@"
    if [[ "$ONE_SHOT" -eq 1 ]]; then
        render_frame
        exit 0
    fi
    run_live
fi
