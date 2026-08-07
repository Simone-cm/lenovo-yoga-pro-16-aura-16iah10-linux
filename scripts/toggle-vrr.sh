#!/bin/bash
# Toggle Variable Refresh Rate on the laptop display via Mutter's
# DisplayConfig D-Bus API (GNOME/Wayland), using only gdbus + perl.
#
# Usage:
#   toggle-vrr.sh on|off   set VRR explicitly
#   toggle-vrr.sh kick     flip VRR to the opposite state and back
#                          (forces a full modeset; workaround for GNOME/Mutter
#                          picking the wrong backlight/display after resume)
#
# Rebuilds the full ApplyMonitorsConfig payload from the current state, so
# any other connected monitors (e.g. external display while docked) are
# preserved unchanged on their current mode -- only the target connector's
# mode gets the +vrr suffix added/removed.
set -euo pipefail

BUS_DEST=org.gnome.Mutter.DisplayConfig
BUS_PATH=/org/gnome/Mutter/DisplayConfig
TARGET_CONNECTOR_PATTERN='^eDP-'   # built-in laptop panel

get_state() {
    gdbus call --session -d "$BUS_DEST" -o "$BUS_PATH" \
        -m org.gnome.Mutter.DisplayConfig.GetCurrentState
}

# Splits GetCurrentState's output and fills globals:
#   SERIAL, TARGET_CONNECTOR, TARGET_CURRENT_MODE, NEW_LOGICAL(want_on)
# via build_new_logical().
declare -A CURMODE

read_state() {
    local out monitors_section logical_section inner
    out=$(get_state)
    SERIAL=$(grep -oP '^\(uint32 \K[0-9]+' <<<"$out")

    monitors_section=$(perl -0777 -ne "print \$1 if /^\\(uint32 \\d+, \\[(.*)\\}\\)\\], \\[\\(/s" <<<"$out")
    logical_section=$(perl -0777 -ne "print \$1 if /\\}\\)\\], (\\[\\(.*\\}\\)\\])/s" <<<"$out")
    inner=$(perl -0777 -ne "print \$1 if /^\\[(.*)\\]\$/s" <<<"$logical_section")

    CURMODE=()
    local mchunks c conn mode
    mapfile -d '' mchunks < <(perl -0777 -ne 'print join("\0", split /(?=\(\(\x27)/), "\0"' <<<"$monitors_section")
    for c in "${mchunks[@]}"; do
        [[ -z "$c" ]] && continue
        conn=$(grep -oP "^\(\('\K[^']+" <<<"$c")
        mode=$(grep -oP "'[0-9]+x[0-9]+@[0-9.]+(\+vrr)?'(?=, [0-9.]+, [0-9.]+, [0-9.]+, [0-9.]+, \[[0-9., ]+\], \{[^}]*'is-current': <true>)" <<<"$c" | tr -d "'")
        CURMODE["$conn"]="$mode"
    done

    TARGET_CONNECTOR=""
    for conn in "${!CURMODE[@]}"; do
        if [[ "$conn" =~ $TARGET_CONNECTOR_PATTERN ]]; then
            TARGET_CONNECTOR="$conn"
            break
        fi
    done
    if [[ -z "$TARGET_CONNECTOR" ]]; then
        echo "no connector matching $TARGET_CONNECTOR_PATTERN found" >&2
        exit 1
    fi
    TARGET_CURRENT_MODE="${CURMODE[$TARGET_CONNECTOR]}"

    LOGICAL_INNER="$inner"
}

# Rebuilds the full logical-monitors argument, substituting the target
# connector's mode with $1's desired VRR state ("on"/"off") and leaving
# every other connector on its current mode.
build_new_logical() {
    local want_on="$1" lchunks c x y scale transform primary conns mon_parts new_parts conn mode base
    new_parts=()
    mapfile -d '' lchunks < <(perl -0777 -ne 'print join("\0", split /(?=\(\d)/), "\0"' <<<"$LOGICAL_INNER")
    for c in "${lchunks[@]}"; do
        [[ -z "$c" ]] && continue
        x=$(grep -oP '^\(\K[0-9]+' <<<"$c")
        y=$(grep -oP '^\([0-9]+, \K[0-9]+' <<<"$c")
        scale=$(grep -oP '^\([0-9]+, [0-9]+, \K[0-9.]+' <<<"$c")
        transform=$(grep -oP 'uint32 \K[0-9]+' <<<"$c")
        primary=$(grep -oP '(true|false)(?=, \[)' <<<"$c")
        conns=$(grep -oP "\('\K[^']+(?=', '[^']*', '[^']*', '[^']*'\))" <<<"$c")
        mon_parts=()
        while IFS= read -r conn; do
            [[ -z "$conn" ]] && continue
            mode="${CURMODE[$conn]}"
            if [[ "$conn" == "$TARGET_CONNECTOR" ]]; then
                base="${mode%+vrr}"
                if [[ "$want_on" == on ]]; then mode="${base}+vrr"; else mode="$base"; fi
            fi
            mon_parts+=("('$conn', '$mode', {})")
        done <<<"$conns"
        mon_joined=$(IFS=,; echo "${mon_parts[*]}")
        new_parts+=("($x, $y, $scale, uint32 $transform, $primary, [$mon_joined])")
    done
    NEW_LOGICAL=$(IFS=,; echo "[${new_parts[*]}]")
}

apply_vrr() {
    local want_on="$1"
    read_state
    local base="${TARGET_CURRENT_MODE%+vrr}"
    local desired
    if [[ "$want_on" == "on" ]]; then
        desired="${base}+vrr"
    else
        desired="$base"
    fi
    if [[ "$desired" == "$TARGET_CURRENT_MODE" ]]; then
        echo "VRR already $want_on"
        return
    fi
    build_new_logical "$want_on"
    gdbus call --session -d "$BUS_DEST" -o "$BUS_PATH" \
        -m org.gnome.Mutter.DisplayConfig.ApplyMonitorsConfig \
        "$SERIAL" 1 "$NEW_LOGICAL" "{}" >/dev/null
    echo "VRR set to $want_on"
}

case "${1:-}" in
    on|off)
        apply_vrr "$1"
        ;;
    kick)
        read_state
        if [[ "$TARGET_CURRENT_MODE" == *+vrr ]]; then was_on=on; else was_on=off; fi
        if [[ "$was_on" == "on" ]]; then apply_vrr off; else apply_vrr on; fi
        sleep 1
        apply_vrr "$was_on"
        ;;
    *)
        echo "usage: toggle-vrr.sh on|off|kick" >&2
        exit 1
        ;;
esac
