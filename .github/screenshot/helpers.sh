# Sourced into every `sh` setup block. $APP, $LIBRARY and $DOCTOPUS are set.
# The GUI-scripting helpers go through System Events, which needs the
# Accessibility access the hosted macOS runners grant to bash and osascript.

# Brings Doctopus to the front.
activate() {
    osascript -e 'tell application "Doctopus" to activate'
}

# Clicks a menu item: `menu Document "Quick Look"`, or a submenu item with
# `menu File "Open Recent" "Clear Menu"`.
menu() {
    activate
    osascript - "$@" <<'EOF'
on run path
    tell application "System Events" to tell process "Doctopus"
        set target to menu bar item (item 1 of path) of menu bar 1
        repeat with name in rest of path
            set target to menu item (name as text) of menu 1 of target
        end repeat
        click target
    end tell
end run
EOF
}

# Types a key with modifiers: `keys , command` opens Settings, `keys o command
# shift` Quick Open. Named keys: return, escape, tab, space, delete, up, down,
# left, right.
keys() {
    local key="$1"; shift
    local using="" m
    for m in "$@"; do
        case "$m" in
            command|shift|option|control) using="${using:+$using, }$m down" ;;
            *) echo "keys: unknown modifier '$m'" >&2; return 1 ;;
        esac
    done
    local stroke
    case "$key" in
        return) stroke="key code 36" ;; escape) stroke="key code 53" ;;
        tab) stroke="key code 48" ;; space) stroke="key code 49" ;;
        delete) stroke="key code 51" ;; up) stroke="key code 126" ;;
        down) stroke="key code 125" ;; left) stroke="key code 123" ;;
        right) stroke="key code 124" ;;
        *) key="${key//\\/\\\\}"; stroke="keystroke \"${key//\"/\\\"}\"" ;;
    esac
    [ -n "$using" ] && stroke="$stroke using {$using}"
    activate
    osascript -e "tell application \"System Events\" to $stroke"
}

# Types text into whatever has focus.
type_text() {
    activate
    osascript - "$1" <<'EOF'
on run {t}
    tell application "System Events" to keystroke t
end run
EOF
}

# Waits until a Doctopus window whose title contains $1 is on screen.
wait_window() {
    local title="$1" timeout="${2:-20}"
    local deadline=$((SECONDS + timeout))
    while [ $SECONDS -lt $deadline ]; do
        "$WINDOWS" Doctopus | cut -f6 | grep -qiF -- "$title" && return 0
        sleep 0.5
    done
    echo "no window titled '$title' after ${timeout}s" >&2
    return 1
}
