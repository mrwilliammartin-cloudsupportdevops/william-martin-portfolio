#!/bin/bash
set -u
set -o pipefail
BASE_DIR="/var/www/html/network-scanner"
DATA_DIR="$BASE_DIR/data"
OUTPUT_FILE="$DATA_DIR/scan_output.txt"
LOG_FILE="$DATA_DIR/scan_errors.log"
HISTORY_FILE="$DATA_DIR/scan_history.csv"
LOCK_FILE="/tmp/network-scanner.lock"
TARGET="${TARGET:-192.168.1.0/24}"
mkdir -p "$DATA_DIR"
touch "$LOG_FILE"
chown root:www-data "$LOG_FILE" 2>/dev/null || true
chmod 640 "$LOG_FILE" 2>/dev/null || true
if [[ ! -f "$HISTORY_FILE" ]]; then echo 'timestamp,status,scanned_ips,hosts_up,duration_seconds,message' > "$HISTORY_FILE"; fi
chown root:www-data "$HISTORY_FILE" 2>/dev/null || true
chmod 640 "$HISTORY_FILE" 2>/dev/null || true
exec 200>"$LOCK_FILE"
if ! flock -n 200; then printf '%s - WARNING: Previous scan is still running; skipping this run.\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"; exit 0; fi
log(){ printf '%s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"; }
record(){ printf '%s,%s,%s,%s,%s,%s\n' "$1" "$2" "$3" "$4" "$5" "${6//,/;}" >> "$HISTORY_FILE"; }
if ! command -v nmap >/dev/null 2>&1; then TS="$(date '+%Y-%m-%d %H:%M:%S')"; log 'ERROR: nmap is not installed.'; record "$TS" FAILED 0 0 0 'Nmap is not installed'; exit 1; fi
if ! command -v ip >/dev/null 2>&1; then TS="$(date '+%Y-%m-%d %H:%M:%S')"; log 'ERROR: ip command is not available.'; record "$TS" FAILED 0 0 0 'ip command is not available'; exit 1; fi
TMP_FILE="$(mktemp "$DATA_DIR/.scan_tmp.XXXXXX")"
trap 'rm -f "$TMP_FILE"' EXIT
START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
START_EPOCH="$(date +%s)"
if ! ip route get "${TARGET%/*}" >/dev/null 2>&1; then
  log "WARNING: Target $TARGET is not routable from this host."
  AUTO_TARGET="$(ip -4 route show scope link | awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/ && $1 !~ /^127\./ && $1 !~ /^169\.254\./ && $1 !~ /^100\.64\./ {print $1; exit}')"
  if [[ -n "$AUTO_TARGET" ]] && ip route get "${AUTO_TARGET%/*}" >/dev/null 2>&1; then TARGET="$AUTO_TARGET"; log "INFO: Automatically selected routable local target $TARGET."; else log 'ERROR: No suitable routable IPv4 network was detected.'; record "$START_TIME" FAILED 0 0 0 'Target is not routable and no local subnet was detected'; exit 1; fi
fi
log "Starting network scan of $TARGET."
{
 echo "# Scan started: $START_TIME"
 echo "# Target range: $TARGET"
 echo "# Scanner host: $(hostname)"
 echo "# Scanner command: nmap -sV -T4 --open $TARGET"
 echo '#'
 nmap -sV -T4 --open "$TARGET"
} > "$TMP_FILE" 2>>"$LOG_FILE"
NMAP_RC=$?
END_EPOCH="$(date +%s)"
DURATION=$((END_EPOCH-START_EPOCH))
END_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
if [[ $NMAP_RC -ne 0 ]]; then log 'ERROR: Nmap command failed. Previous scan preserved.'; record "$END_TIME" FAILED 0 0 "$DURATION" 'Nmap command failed'; exit 1; fi
DONE="$(grep -E '^Nmap done:' "$TMP_FILE" | tail -n1)"
if [[ -z "$DONE" ]] || ! printf '%s\n' "$DONE" | grep -qE '^Nmap done: [1-9][0-9]* IP addresses \('; then log 'ERROR: Nmap returned no scanned IP addresses. Previous scan preserved.'; record "$END_TIME" FAILED 0 0 "$DURATION" 'Nmap returned no scanned IP addresses'; exit 1; fi
SCANNED_IPS="$(printf '%s\n' "$DONE" | sed -E 's/^Nmap done: ([0-9]+) IP addresses.*/\1/')"
HOSTS_UP="$(printf '%s\n' "$DONE" | sed -E 's/^Nmap done: [0-9]+ IP addresses \(([0-9]+) hosts? up\).*/\1/')"
[[ -z "$HOSTS_UP" ]] && HOSTS_UP=0
[[ -z "$SCANNED_IPS" || "$SCANNED_IPS" -eq 0 ]] && { log 'ERROR: Nmap reported 0 scanned IP addresses. Previous scan preserved.'; record "$END_TIME" FAILED 0 0 "$DURATION" 'Nmap returned no scanned IP addresses'; exit 1; }
{ echo '#'; echo "# Scan completed: $END_TIME"; } >> "$TMP_FILE"
mv "$TMP_FILE" "$OUTPUT_FILE"
chown root:www-data "$OUTPUT_FILE" 2>/dev/null || true
chmod 640 "$OUTPUT_FILE" 2>/dev/null || true
record "$END_TIME" SUCCESS "$SCANNED_IPS" "$HOSTS_UP" "$DURATION" 'Scan completed successfully'
log "Network scan completed successfully. $SCANNED_IPS IP addresses scanned; $HOSTS_UP hosts up."
exit 0
