#!/usr/bin/env bash
#
# zfs-scrub.sh — automated ZFS pool scrub with logging and Gotify notifications.
#
# Intended to be invoked periodically by cron on Debian 12 / Proxmox VE 8.x.
# Deploy path: /home/zfs-scrub/zfs-scrub.sh
#
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Configuration — edit these values for your environment.
# ---------------------------------------------------------------------------
readonly POOL="" # ur zfs pool
readonly GOTIFY_URL="http://ip:8080"
readonly GOTIFY_TOKEN=""
readonly LOG_DIR="/home/zfs-scrub/logs"
readonly LOG_FILE="${LOG_DIR}/zfs-scrub.log"
readonly LOCK_FILE="/home/zfs-scrub/zfs-scrub.lock"
readonly CHECK_INTERVAL=60 # seconds between scrub-progress checks

# Gotify notification priorities.
readonly GOTIFY_PRIORITY_INFO=4
readonly GOTIFY_PRIORITY_ERROR=8

# File descriptor used to hold the flock for the lifetime of the script.
# Fixed fd number (not auto-assigned via `exec {VAR}>`, since bash's
# fd-variable syntax writes to the variable, which conflicts with readonly).
readonly LOCK_FD=200

# ---------------------------------------------------------------------------
# Globals populated during execution (used by the final report).
# ---------------------------------------------------------------------------
SCRUB_START_EPOCH=""
SCRUB_START_HUMAN=""
DIE_ALREADY_NOTIFIED=0

# ---------------------------------------------------------------------------
# timestamp — print current time as "YYYY-MM-DD HH:MM:SS".
# ---------------------------------------------------------------------------
timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# ---------------------------------------------------------------------------
# log <message> — write a timestamped line to the log file and to journald.
# ---------------------------------------------------------------------------
log() {
    local message="$1"
    printf '[%s] %s\n' "$(timestamp)" "$message" >>"$LOG_FILE"
    logger -t zfs-scrub -- "$message"
}

# ---------------------------------------------------------------------------
# notify <title> <message> [priority] — send a Gotify push notification.
#
# Failures to reach Gotify are logged but never abort the script, per spec.
# ---------------------------------------------------------------------------
notify() {
    local title="$1"
    local message="$2"
    local priority="${3:-$GOTIFY_PRIORITY_INFO}"

    if [[ -z "$GOTIFY_TOKEN" ]]; then
        log "WARNING: GOTIFY_TOKEN is empty, skipping notification: ${title}"
        return 0
    fi

    if ! curl --silent --show-error --fail \
        --max-time 10 \
        --form "title=${title}" \
        --form "message=${message}" \
        --form "priority=${priority}" \
        "${GOTIFY_URL}/message?token=${GOTIFY_TOKEN}" >/dev/null 2>>"$LOG_FILE"; then
        log "WARNING: failed to send Gotify notification: ${title}"
    fi
}

# ---------------------------------------------------------------------------
# die <message> — log a fatal error, notify Gotify, and exit non-zero.
# ---------------------------------------------------------------------------
die() {
    local message="$1"
    log "ERROR: ${message}"
    notify "ZFS Scrub Error" "${message}" "$GOTIFY_PRIORITY_ERROR"
    DIE_ALREADY_NOTIFIED=1
    exit 1
}

# ---------------------------------------------------------------------------
# require <command> — abort via die() if a required command is not on PATH.
# ---------------------------------------------------------------------------
require() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        die "required command '${cmd}' not found in PATH"
    fi
}

# ---------------------------------------------------------------------------
# on_error — trap handler for ERR. Ensures unexpected failures are still
# logged and reported even if they did not go through die().
# ---------------------------------------------------------------------------
on_error() {
    local exit_code=$?
    local line_no=$1
    if [[ "$DIE_ALREADY_NOTIFIED" -eq 0 ]]; then
        log "ERROR: unexpected failure at line ${line_no} (exit code ${exit_code})"
        notify "ZFS Scrub Error" "Unexpected failure at line ${line_no} (exit code ${exit_code})" "$GOTIFY_PRIORITY_ERROR"
    fi
}

# ---------------------------------------------------------------------------
# on_exit — trap handler for EXIT. Releases the lock (closing the fd is
# sufficient since flock is held for the process lifetime) and cleans up
# any temporary files created during this run.
# ---------------------------------------------------------------------------
on_exit() {
    if [[ -n "${TMP_STATUS_FILE:-}" && -f "${TMP_STATUS_FILE}" ]]; then
        rm -f -- "$TMP_STATUS_FILE"
    fi
    eval "exec ${LOCK_FD}>&-" 2>/dev/null || true
}

trap 'on_error $LINENO' ERR
trap on_exit EXIT

# ---------------------------------------------------------------------------
# acquire_lock — take a non-blocking flock on LOCK_FILE. If another instance
# already holds it, exit immediately (not an error condition).
# ---------------------------------------------------------------------------
acquire_lock() {
    eval "exec ${LOCK_FD}>\"\$LOCK_FILE\""
    if ! flock -n "$LOCK_FD"; then
        log "Another instance is already running (lock held on ${LOCK_FILE}). Exiting."
        exit 0
    fi
}

# ---------------------------------------------------------------------------
# pool_exists — verify the configured pool is known to ZFS.
# ---------------------------------------------------------------------------
pool_exists() {
    zpool list -H -o name "$POOL" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# scrub_in_progress — true if a scrub is currently running on the pool.
# ---------------------------------------------------------------------------
scrub_in_progress() {
    zpool status "$POOL" | grep -q 'scrub in progress'
}

# ---------------------------------------------------------------------------
# scrub_is_complete — true once the scan line reports a finished scrub
# (either successfully completed, or cancelled/aborted).
# ---------------------------------------------------------------------------
scrub_is_complete() {
    ! scrub_in_progress
}

# ---------------------------------------------------------------------------
# collect_pool_status — extract overall pool state, the scan: summary line,
# and the errors: summary line from `zpool status`.
#
# Output format (three lines), consumed by build_report():
#   STATE=<state>
#   SCAN=<scan summary, collapsed to one line>
#   ERRORS=<errors summary>
# ---------------------------------------------------------------------------
collect_pool_status() {
    local status_text="$1"
    local state="" errors="" scan_lines="" in_scan=0
    local trimmed

    while IFS= read -r line; do
        # zpool right-pads the "pool/state/scan" labels to align their
        # colons, so the exact leading whitespace varies. Trim it instead
        # of matching a fixed number of spaces.
        trimmed="${line#"${line%%[![:space:]]*}"}"

        case "$trimmed" in
            state:\ *)
                state="${trimmed#state: }"
                ;;
            scan:\ *)
                in_scan=1
                scan_lines="${trimmed#scan: }"
                ;;
            errors:\ *)
                in_scan=0
                errors="${trimmed#errors: }"
                ;;
            config:*|'')
                in_scan=0
                ;;
            *)
                if [[ "$in_scan" -eq 1 ]]; then
                    scan_lines="${scan_lines} ${trimmed}"
                fi
                ;;
        esac
    done <<<"$status_text"

    printf 'STATE=%s\n' "$state"
    printf 'SCAN=%s\n' "$scan_lines"
    printf 'ERRORS=%s\n' "$errors"
}

# ---------------------------------------------------------------------------
# collect_devices — parse the per-vdev/per-device table from `zpool status`
# output, printing one line per device as:
#   <name> STATE=<state> READ=<n> WRITE=<n> CKSUM=<n>
#
# Parses field-by-field (name, state, read, write, cksum are always the
# first five whitespace-separated fields on a device line) rather than
# matching disk-name patterns, so it survives future device naming schemes
# (e.g. /dev/disk/by-id paths from `zpool status -P`).
# ---------------------------------------------------------------------------
collect_devices() {
    local status_text="$1"
    local in_config=0
    local seen_header=0

    while IFS= read -r line; do
        if [[ "$line" == config:* ]]; then
            in_config=1
            continue
        fi
        if [[ "$in_config" -eq 0 ]]; then
            continue
        fi
        # `config:` is followed by a blank line, then the NAME header, then
        # the device rows, then a final blank line before `errors:`. Only
        # the *second* blank line (after we've seen real rows) ends the
        # block -- the first one, before the header, must be skipped.
        if [[ -z "$line" ]]; then
            if [[ "$seen_header" -eq 1 ]]; then
                break
            fi
            continue
        fi

        # Skip the header row ("NAME  STATE  READ  WRITE  CKSUM ...").
        local first_field
        first_field=$(echo "$line" | awk '{print $1}')
        if [[ "$first_field" == "NAME" ]]; then
            seen_header=1
            continue
        fi
        if [[ "$first_field" == "$POOL" ]]; then
            seen_header=1
            continue
        fi

        # A real device/vdev line has at least 5 whitespace-separated
        # fields: name, state, read, write, cksum.
        local field_count
        field_count=$(echo "$line" | awk '{print NF}')
        if [[ "$field_count" -lt 5 ]]; then
            continue
        fi

        # Skip mirror/raidz vdev header lines (state is always one of
        # ONLINE/DEGRADED/FAULTED/OFFLINE/UNAVAIL/REMOVED for real devices,
        # but vdev group lines share that too — we still want to report
        # them, so no further filtering is needed here).
        echo "$line" | awk '{printf "%s STATE=%s READ=%s WRITE=%s CKSUM=%s\n", $1, $2, $3, $4, $5}'
    done <<<"$status_text"
}

# ---------------------------------------------------------------------------
# collect_smart — for each real disk device found in the pool, report
# SMART health, temperature, power-on hours, reallocated and pending
# sector counts. If smartctl is unavailable, report that plainly without
# treating it as an error.
# ---------------------------------------------------------------------------
collect_smart() {
    local device_names="$1"

    if ! command -v smartctl >/dev/null 2>&1; then
        printf 'SMART unavailable\n'
        return 0
    fi

    local dev resolved_dev
    while IFS= read -r dev; do
        [[ -z "$dev" ]] && continue

        # Device names in `zpool status` come in whatever form the pool was
        # created with: short kernel names (sda, sdb), full paths (-P), or
        # -- most commonly on Proxmox/ZoL -- by-id labels like
        # "ata-WDC_..." or "usb-JMicron_...". Try each known location in
        # turn rather than assuming one convention.
        if [[ "$dev" == /dev/* ]]; then
            resolved_dev="$dev"
        elif [[ -e "/dev/disk/by-id/${dev}" ]]; then
            resolved_dev="/dev/disk/by-id/${dev}"
        elif [[ -e "/dev/${dev}" ]]; then
            resolved_dev="/dev/${dev}"
        else
            printf '%s: device node not found, skipping SMART\n' "$dev"
            continue
        fi

        if [[ ! -e "$resolved_dev" ]]; then
            printf '%s: device node not found, skipping SMART\n' "$dev"
            continue
        fi

        # smartctl's exit code is a bitmask that can be non-zero even on a
        # successful read (e.g. a bit is set when an attribute is below
        # threshold) -- exactly the failing-disk case we most need to see.
        # So we must not treat a non-zero exit as failure; only an empty
        # output means the query genuinely didn't return usable data.
        #
        # USB-SATA bridges (e.g. JMicron) frequently don't answer plain ATA
        # passthrough and need an explicit -d type to expose SMART
        # attributes. Try auto-detect first, then fall back to the device
        # types most commonly needed for such bridges.
        local smart_output device_type
        for device_type in "" "-d sat" "-d usbjmicron,0" "-d usbjmicron"; do
            # shellcheck disable=SC2086 -- device_type is an intentional word split (may be empty or "-d X")
            smart_output=$(smartctl -H -A $device_type "$resolved_dev" 2>/dev/null || true)
            if echo "$smart_output" | grep -qi 'SMART overall-health\|Temperature_Celsius\|Power_On_Hours'; then
                break
            fi
        done
        if [[ -z "$smart_output" ]]; then
            printf '%s: smartctl query failed\n' "$dev"
            continue
        fi

        local health temp power_on realloc pending
        health=$(echo "$smart_output" | grep -i 'SMART overall-health' | awk -F': ' '{print $2}')
        [[ -z "$health" ]] && health="unknown"

        temp=$(echo "$smart_output" | awk '/Temperature_Celsius/ {print $10; exit}')
        [[ -z "$temp" ]] && temp="unknown"

        power_on=$(echo "$smart_output" | awk '/Power_On_Hours/ {print $10; exit}')
        [[ -z "$power_on" ]] && power_on="unknown"

        realloc=$(echo "$smart_output" | awk '/Reallocated_Sector_Ct/ {print $10; exit}')
        [[ -z "$realloc" ]] && realloc="unknown"

        pending=$(echo "$smart_output" | awk '/Current_Pending_Sector/ {print $10; exit}')
        [[ -z "$pending" ]] && pending="unknown"

        printf '%s: Health=%s Temp=%sC PowerOnHours=%s ReallocatedSectors=%s PendingSectors=%s\n' \
            "$dev" "$health" "$temp" "$power_on" "$realloc" "$pending"
    done <<<"$device_names"
}

# ---------------------------------------------------------------------------
# extract_device_names — pull bare device/vdev names out of the config
# block (used to drive collect_smart). Excludes the pool line, the vdev
# group lines (mirror-N, raidz1-N, etc.) and spares/cache/log headers,
# keeping only lines that look like actual leaf devices.
# ---------------------------------------------------------------------------
extract_device_names() {
    local status_text="$1"
    local in_config=0
    local seen_header=0

    while IFS= read -r line; do
        if [[ "$line" == config:* ]]; then
            in_config=1
            continue
        fi
        if [[ "$in_config" -eq 0 ]]; then
            continue
        fi
        # See the comment in collect_devices(): the blank line right after
        # `config:` (before the NAME header) must not end the block.
        if [[ -z "$line" ]]; then
            if [[ "$seen_header" -eq 1 ]]; then
                break
            fi
            continue
        fi

        local first_field
        first_field=$(echo "$line" | awk '{print $1}')

        case "$first_field" in
            NAME|"$POOL"|mirror-*|raidz*-*|spares|logs|cache)
                seen_header=1
                continue
                ;;
        esac

        [[ -z "$first_field" ]] && continue
        seen_header=1
        echo "$first_field"
    done <<<"$status_text"
}

# ---------------------------------------------------------------------------
# format_duration <seconds> — render an elapsed time as "Xd Xh Xm Xs",
# omitting leading zero components.
# ---------------------------------------------------------------------------
format_duration() {
    local total_seconds="$1"
    local days=$((total_seconds / 86400))
    local hours=$(((total_seconds % 86400) / 3600))
    local minutes=$(((total_seconds % 3600) / 60))
    local seconds=$((total_seconds % 60))

    local result=""
    [[ "$days" -gt 0 ]] && result="${result}${days}d "
    [[ "$hours" -gt 0 || -n "$result" ]] && result="${result}${hours}h "
    [[ "$minutes" -gt 0 || -n "$result" ]] && result="${result}${minutes}m "
    result="${result}${seconds}s"

    echo "$result"
}

# ---------------------------------------------------------------------------
# build_report — assemble the final Gotify message body from collected data.
# ---------------------------------------------------------------------------
build_report() {
    local status_text="$1"
    local finish_epoch="$2"
    local pool_info devices_info smart_info duration_str finish_human
    local state scan errors device_names has_errors

    pool_info=$(collect_pool_status "$status_text")
    state=$(echo "$pool_info" | sed -n 's/^STATE=//p')
    scan=$(echo "$pool_info" | sed -n 's/^SCAN=//p')
    errors=$(echo "$pool_info" | sed -n 's/^ERRORS=//p')

    devices_info=$(collect_devices "$status_text")
    device_names=$(extract_device_names "$status_text")
    smart_info=$(collect_smart "$device_names")

    finish_human=$(date -d "@${finish_epoch}" '+%Y-%m-%d %H:%M:%S')
    duration_str=$(format_duration $((finish_epoch - SCRUB_START_EPOCH)))

    has_errors=0
    if [[ "$errors" != "No known data errors" && -n "$errors" ]]; then
        has_errors=1
    fi
    if echo "$devices_info" | grep -qvE 'READ=0 WRITE=0 CKSUM=0'; then
        has_errors=1
    fi

    {
        printf 'ZFS Scrub Completed\n\n'
        printf 'Pool: %s\n' "$POOL"
        printf 'State: %s\n' "$state"
        printf 'Started: %s\n' "$SCRUB_START_HUMAN"
        printf 'Finished: %s\n' "$finish_human"
        printf 'Duration: %s\n\n' "$duration_str"
        printf 'scan: %s\n\n' "$scan"
        printf 'errors: %s\n\n' "$errors"
        printf 'Devices:\n%s\n\n' "$devices_info"
        printf 'SMART:\n%s\n' "$smart_info"

        if [[ "$has_errors" -eq 1 ]]; then
            printf '\n--- zpool status -v ---\n%s\n' "$(zpool status -v "$POOL")"
        fi
    }
}

# ---------------------------------------------------------------------------
# send_report — deliver the assembled report to Gotify and to the log file.
# ---------------------------------------------------------------------------
send_report() {
    local report="$1"
    log "Scrub finished. Report follows."
    printf '%s\n' "$report" >>"$LOG_FILE"
    notify "ZFS Scrub Completed" "$report" "$GOTIFY_PRIORITY_INFO"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    mkdir -p "$LOG_DIR"

    require zpool
    require curl
    require flock
    require logger

    # Lock first so two concurrent invocations can't both pass the
    # "scrub already running" check and both issue `zpool scrub`.
    acquire_lock

    if ! pool_exists; then
        die "pool '${POOL}' does not exist"
    fi

    if scrub_in_progress; then
        log "Scrub already in progress on pool '${POOL}'. Exiting."
        exit 0
    fi

    SCRUB_START_EPOCH=$(date '+%s')
    SCRUB_START_HUMAN=$(timestamp)

    log "Starting scrub on pool '${POOL}'."
    notify "ZFS Scrub Started" "Scrub started on pool ${POOL} at ${SCRUB_START_HUMAN}." "$GOTIFY_PRIORITY_INFO"

    zpool scrub "$POOL"

    until scrub_is_complete; do
        sleep "$CHECK_INTERVAL"
    done

    local finish_epoch status_text report
    finish_epoch=$(date '+%s')
    status_text=$(zpool status -P "$POOL")

    report=$(build_report "$status_text" "$finish_epoch")
    send_report "$report"

    log "Scrub cycle complete for pool '${POOL}'."
}

main "$@"
#!/usr/bin/env bash
#
# zfs-scrub.sh — automated ZFS pool scrub with logging and Gotify notifications.
#
# Intended to be invoked periodically by cron on Debian 12 / Proxmox VE 8.x.
# Deploy path: /home/zfs-scrub/zfs-scrub.sh
#
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Configuration — edit these values for your environment.
# ---------------------------------------------------------------------------
readonly POOL="" # ur zfs pool 
readonly GOTIFY_URL="http://ip:port"
readonly GOTIFY_TOKEN=""
readonly LOG_DIR="/home/zfs-scrub/logs"
readonly LOG_FILE="${LOG_DIR}/zfs-scrub.log"
readonly LOCK_FILE="/home/zfs-scrub/zfs-scrub.lock"
readonly CHECK_INTERVAL=60 # seconds between scrub-progress checks

# Gotify notification priorities.
readonly GOTIFY_PRIORITY_INFO=4
readonly GOTIFY_PRIORITY_ERROR=8

# File descriptor used to hold the flock for the lifetime of the script.
# Fixed fd number (not auto-assigned via `exec {VAR}>`, since bash's
# fd-variable syntax writes to the variable, which conflicts with readonly).
readonly LOCK_FD=200

# ---------------------------------------------------------------------------
# Globals populated during execution (used by the final report).
# ---------------------------------------------------------------------------
SCRUB_START_EPOCH=""
SCRUB_START_HUMAN=""
DIE_ALREADY_NOTIFIED=0

# ---------------------------------------------------------------------------
# timestamp — print current time as "YYYY-MM-DD HH:MM:SS".
# ---------------------------------------------------------------------------
timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# ---------------------------------------------------------------------------
# log <message> — write a timestamped line to the log file and to journald.
# ---------------------------------------------------------------------------
log() {
    local message="$1"
    printf '[%s] %s\n' "$(timestamp)" "$message" >>"$LOG_FILE"
    logger -t zfs-scrub -- "$message"
}

# ---------------------------------------------------------------------------
# notify <title> <message> [priority] — send a Gotify push notification.
#
# Failures to reach Gotify are logged but never abort the script, per spec.
# ---------------------------------------------------------------------------
notify() {
    local title="$1"
    local message="$2"
    local priority="${3:-$GOTIFY_PRIORITY_INFO}"

    if [[ -z "$GOTIFY_TOKEN" ]]; then
        log "WARNING: GOTIFY_TOKEN is empty, skipping notification: ${title}"
        return 0
    fi

    if ! curl --silent --show-error --fail \
        --max-time 10 \
        --form "title=${title}" \
        --form "message=${message}" \
        --form "priority=${priority}" \
        "${GOTIFY_URL}/message?token=${GOTIFY_TOKEN}" >/dev/null 2>>"$LOG_FILE"; then
        log "WARNING: failed to send Gotify notification: ${title}"
    fi
}

# ---------------------------------------------------------------------------
# die <message> — log a fatal error, notify Gotify, and exit non-zero.
# ---------------------------------------------------------------------------
die() {
    local message="$1"
    log "ERROR: ${message}"
    notify "ZFS Scrub Error" "${message}" "$GOTIFY_PRIORITY_ERROR"
    DIE_ALREADY_NOTIFIED=1
    exit 1
}

# ---------------------------------------------------------------------------
# require <command> — abort via die() if a required command is not on PATH.
# ---------------------------------------------------------------------------
require() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        die "required command '${cmd}' not found in PATH"
    fi
}

# ---------------------------------------------------------------------------
# on_error — trap handler for ERR. Ensures unexpected failures are still
# logged and reported even if they did not go through die().
# ---------------------------------------------------------------------------
on_error() {
    local exit_code=$?
    local line_no=$1
    if [[ "$DIE_ALREADY_NOTIFIED" -eq 0 ]]; then
        log "ERROR: unexpected failure at line ${line_no} (exit code ${exit_code})"
        notify "ZFS Scrub Error" "Unexpected failure at line ${line_no} (exit code ${exit_code})" "$GOTIFY_PRIORITY_ERROR"
    fi
}

# ---------------------------------------------------------------------------
# on_exit — trap handler for EXIT. Releases the lock (closing the fd is
# sufficient since flock is held for the process lifetime) and cleans up
# any temporary files created during this run.
# ---------------------------------------------------------------------------
on_exit() {
    if [[ -n "${TMP_STATUS_FILE:-}" && -f "${TMP_STATUS_FILE}" ]]; then
        rm -f -- "$TMP_STATUS_FILE"
    fi
    eval "exec ${LOCK_FD}>&-" 2>/dev/null || true
}

trap 'on_error $LINENO' ERR
trap on_exit EXIT

# ---------------------------------------------------------------------------
# acquire_lock — take a non-blocking flock on LOCK_FILE. If another instance
# already holds it, exit immediately (not an error condition).
# ---------------------------------------------------------------------------
acquire_lock() {
    eval "exec ${LOCK_FD}>\"\$LOCK_FILE\""
    if ! flock -n "$LOCK_FD"; then
        log "Another instance is already running (lock held on ${LOCK_FILE}). Exiting."
        exit 0
    fi
}

# ---------------------------------------------------------------------------
# pool_exists — verify the configured pool is known to ZFS.
# ---------------------------------------------------------------------------
pool_exists() {
    zpool list -H -o name "$POOL" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# scrub_in_progress — true if a scrub is currently running on the pool.
# ---------------------------------------------------------------------------
scrub_in_progress() {
    zpool status "$POOL" | grep -q 'scrub in progress'
}

# ---------------------------------------------------------------------------
# scrub_is_complete — true once the scan line reports a finished scrub
# (either successfully completed, or cancelled/aborted).
# ---------------------------------------------------------------------------
scrub_is_complete() {
    ! scrub_in_progress
}

# ---------------------------------------------------------------------------
# collect_pool_status — extract overall pool state, the scan: summary line,
# and the errors: summary line from `zpool status`.
#
# Output format (three lines), consumed by build_report():
#   STATE=<state>
#   SCAN=<scan summary, collapsed to one line>
#   ERRORS=<errors summary>
# ---------------------------------------------------------------------------
collect_pool_status() {
    local status_text="$1"
    local state="" errors="" scan_lines="" in_scan=0
    local trimmed

    while IFS= read -r line; do
        # zpool right-pads the "pool/state/scan" labels to align their
        # colons, so the exact leading whitespace varies. Trim it instead
        # of matching a fixed number of spaces.
        trimmed="${line#"${line%%[![:space:]]*}"}"

        case "$trimmed" in
            state:\ *)
                state="${trimmed#state: }"
                ;;
            scan:\ *)
                in_scan=1
                scan_lines="${trimmed#scan: }"
                ;;
            errors:\ *)
                in_scan=0
                errors="${trimmed#errors: }"
                ;;
            config:*|'')
                in_scan=0
                ;;
            *)
                if [[ "$in_scan" -eq 1 ]]; then
                    scan_lines="${scan_lines} ${trimmed}"
                fi
                ;;
        esac
    done <<<"$status_text"

    printf 'STATE=%s\n' "$state"
    printf 'SCAN=%s\n' "$scan_lines"
    printf 'ERRORS=%s\n' "$errors"
}

# ---------------------------------------------------------------------------
# collect_devices — parse the per-vdev/per-device table from `zpool status`
# output, printing one line per device as:
#   <name> STATE=<state> READ=<n> WRITE=<n> CKSUM=<n>
#
# Parses field-by-field (name, state, read, write, cksum are always the
# first five whitespace-separated fields on a device line) rather than
# matching disk-name patterns, so it survives future device naming schemes
# (e.g. /dev/disk/by-id paths from `zpool status -P`).
# ---------------------------------------------------------------------------
collect_devices() {
    local status_text="$1"
    local in_config=0
    local seen_header=0

    while IFS= read -r line; do
        if [[ "$line" == config:* ]]; then
            in_config=1
            continue
        fi
        if [[ "$in_config" -eq 0 ]]; then
            continue
        fi
        # `config:` is followed by a blank line, then the NAME header, then
        # the device rows, then a final blank line before `errors:`. Only
        # the *second* blank line (after we've seen real rows) ends the
        # block -- the first one, before the header, must be skipped.
        if [[ -z "$line" ]]; then
            if [[ "$seen_header" -eq 1 ]]; then
                break
            fi
            continue
        fi

        # Skip the header row ("NAME  STATE  READ  WRITE  CKSUM ...").
        local first_field
        first_field=$(echo "$line" | awk '{print $1}')
        if [[ "$first_field" == "NAME" ]]; then
            seen_header=1
            continue
        fi
        if [[ "$first_field" == "$POOL" ]]; then
            seen_header=1
            continue
        fi

        # A real device/vdev line has at least 5 whitespace-separated
        # fields: name, state, read, write, cksum.
        local field_count
        field_count=$(echo "$line" | awk '{print NF}')
        if [[ "$field_count" -lt 5 ]]; then
            continue
        fi

        # Skip mirror/raidz vdev header lines (state is always one of
        # ONLINE/DEGRADED/FAULTED/OFFLINE/UNAVAIL/REMOVED for real devices,
        # but vdev group lines share that too — we still want to report
        # them, so no further filtering is needed here).
        echo "$line" | awk '{printf "%s STATE=%s READ=%s WRITE=%s CKSUM=%s\n", $1, $2, $3, $4, $5}'
    done <<<"$status_text"
}

# ---------------------------------------------------------------------------
# collect_smart — for each real disk device found in the pool, report
# SMART health, temperature, power-on hours, reallocated and pending
# sector counts. If smartctl is unavailable, report that plainly without
# treating it as an error.
# ---------------------------------------------------------------------------
collect_smart() {
    local device_names="$1"

    if ! command -v smartctl >/dev/null 2>&1; then
        printf 'SMART unavailable\n'
        return 0
    fi

    local dev resolved_dev
    while IFS= read -r dev; do
        [[ -z "$dev" ]] && continue

        # Device names in `zpool status` may be short (sda, sdb) or full
        # paths (from -P / by-id). Resolve to a smartctl-usable path.
        if [[ "$dev" == /dev/* ]]; then
            resolved_dev="$dev"
        elif [[ -e "/dev/${dev}" ]]; then
            resolved_dev="/dev/${dev}"
        else
            printf '%s: device node not found, skipping SMART\n' "$dev"
            continue
        fi

        if [[ ! -e "$resolved_dev" ]]; then
            printf '%s: device node not found, skipping SMART\n' "$dev"
            continue
        fi

        # smartctl's exit code is a bitmask that can be non-zero even on a
        # successful read (e.g. a bit is set when an attribute is below
        # threshold) -- exactly the failing-disk case we most need to see.
        # So we must not treat a non-zero exit as failure; only an empty
        # output means the query genuinely didn't return usable data.
        local smart_output
        smart_output=$(smartctl -H -A "$resolved_dev" 2>/dev/null || true)
        if [[ -z "$smart_output" ]]; then
            printf '%s: smartctl query failed\n' "$dev"
            continue
        fi

        local health temp power_on realloc pending
        health=$(echo "$smart_output" | grep -i 'SMART overall-health' | awk -F': ' '{print $2}')
        [[ -z "$health" ]] && health="unknown"

        temp=$(echo "$smart_output" | awk '/Temperature_Celsius/ {print $10; exit}')
        [[ -z "$temp" ]] && temp="unknown"

        power_on=$(echo "$smart_output" | awk '/Power_On_Hours/ {print $10; exit}')
        [[ -z "$power_on" ]] && power_on="unknown"

        realloc=$(echo "$smart_output" | awk '/Reallocated_Sector_Ct/ {print $10; exit}')
        [[ -z "$realloc" ]] && realloc="unknown"

        pending=$(echo "$smart_output" | awk '/Current_Pending_Sector/ {print $10; exit}')
        [[ -z "$pending" ]] && pending="unknown"

        printf '%s: Health=%s Temp=%sC PowerOnHours=%s ReallocatedSectors=%s PendingSectors=%s\n' \
            "$dev" "$health" "$temp" "$power_on" "$realloc" "$pending"
    done <<<"$device_names"
}

# ---------------------------------------------------------------------------
# extract_device_names — pull bare device/vdev names out of the config
# block (used to drive collect_smart). Excludes the pool line, the vdev
# group lines (mirror-N, raidz1-N, etc.) and spares/cache/log headers,
# keeping only lines that look like actual leaf devices.
# ---------------------------------------------------------------------------
extract_device_names() {
    local status_text="$1"
    local in_config=0
    local seen_header=0

    while IFS= read -r line; do
        if [[ "$line" == config:* ]]; then
            in_config=1
            continue
        fi
        if [[ "$in_config" -eq 0 ]]; then
            continue
        fi
        # See the comment in collect_devices(): the blank line right after
        # `config:` (before the NAME header) must not end the block.
        if [[ -z "$line" ]]; then
            if [[ "$seen_header" -eq 1 ]]; then
                break
            fi
            continue
        fi

        local first_field
        first_field=$(echo "$line" | awk '{print $1}')

        case "$first_field" in
            NAME|"$POOL"|mirror-*|raidz*-*|spares|logs|cache)
                seen_header=1
                continue
                ;;
        esac

        [[ -z "$first_field" ]] && continue
        seen_header=1
        echo "$first_field"
    done <<<"$status_text"
}

# ---------------------------------------------------------------------------
# format_duration <seconds> — render an elapsed time as "Xd Xh Xm Xs",
# omitting leading zero components.
# ---------------------------------------------------------------------------
format_duration() {
    local total_seconds="$1"
    local days=$((total_seconds / 86400))
    local hours=$(((total_seconds % 86400) / 3600))
    local minutes=$(((total_seconds % 3600) / 60))
    local seconds=$((total_seconds % 60))

    local result=""
    [[ "$days" -gt 0 ]] && result="${result}${days}d "
    [[ "$hours" -gt 0 || -n "$result" ]] && result="${result}${hours}h "
    [[ "$minutes" -gt 0 || -n "$result" ]] && result="${result}${minutes}m "
    result="${result}${seconds}s"

    echo "$result"
}

# ---------------------------------------------------------------------------
# build_report — assemble the final Gotify message body from collected data.
# ---------------------------------------------------------------------------
build_report() {
    local status_text="$1"
    local finish_epoch="$2"
    local pool_info devices_info smart_info duration_str finish_human
    local state scan errors device_names has_errors

    pool_info=$(collect_pool_status "$status_text")
    state=$(echo "$pool_info" | sed -n 's/^STATE=//p')
    scan=$(echo "$pool_info" | sed -n 's/^SCAN=//p')
    errors=$(echo "$pool_info" | sed -n 's/^ERRORS=//p')

    devices_info=$(collect_devices "$status_text")
    device_names=$(extract_device_names "$status_text")
    smart_info=$(collect_smart "$device_names")

    finish_human=$(date -d "@${finish_epoch}" '+%Y-%m-%d %H:%M:%S')
    duration_str=$(format_duration $((finish_epoch - SCRUB_START_EPOCH)))

    has_errors=0
    if [[ "$errors" != "No known data errors" && -n "$errors" ]]; then
        has_errors=1
    fi
    if echo "$devices_info" | grep -qvE 'READ=0 WRITE=0 CKSUM=0'; then
        has_errors=1
    fi

    {
        printf 'ZFS Scrub Completed\n\n'
        printf 'Pool: %s\n' "$POOL"
        printf 'State: %s\n' "$state"
        printf 'Started: %s\n' "$SCRUB_START_HUMAN"
        printf 'Finished: %s\n' "$finish_human"
        printf 'Duration: %s\n\n' "$duration_str"
        printf 'scan: %s\n\n' "$scan"
        printf 'errors: %s\n\n' "$errors"
        printf 'Devices:\n%s\n\n' "$devices_info"
        printf 'SMART:\n%s\n' "$smart_info"

        if [[ "$has_errors" -eq 1 ]]; then
            printf '\n--- zpool status -v ---\n%s\n' "$(zpool status -v "$POOL")"
        fi
    }
}

# ---------------------------------------------------------------------------
# send_report — deliver the assembled report to Gotify and to the log file.
# ---------------------------------------------------------------------------
send_report() {
    local report="$1"
    log "Scrub finished. Report follows."
    printf '%s\n' "$report" >>"$LOG_FILE"
    notify "ZFS Scrub Completed" "$report" "$GOTIFY_PRIORITY_INFO"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    mkdir -p "$LOG_DIR"

    require zpool
    require curl
    require flock
    require logger

    # Lock first so two concurrent invocations can't both pass the
    # "scrub already running" check and both issue `zpool scrub`.
    acquire_lock

    if ! pool_exists; then
        die "pool '${POOL}' does not exist"
    fi

    if scrub_in_progress; then
        log "Scrub already in progress on pool '${POOL}'. Exiting."
        exit 0
    fi

    SCRUB_START_EPOCH=$(date '+%s')
    SCRUB_START_HUMAN=$(timestamp)

    log "Starting scrub on pool '${POOL}'."
    notify "ZFS Scrub Started" "Scrub started on pool ${POOL} at ${SCRUB_START_HUMAN}." "$GOTIFY_PRIORITY_INFO"

    zpool scrub "$POOL"

    until scrub_is_complete; do
        sleep "$CHECK_INTERVAL"
    done

    local finish_epoch status_text report
    finish_epoch=$(date '+%s')
    status_text=$(zpool status -P "$POOL")

    report=$(build_report "$status_text" "$finish_epoch")
    send_report "$report"

    log "Scrub cycle complete for pool '${POOL}'."
}

main "$@"
