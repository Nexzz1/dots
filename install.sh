#!/usr/bin/env bash

# Installs the dotfiles from this repository into ~/.config.
# Usage: ./install.sh [--yes] [--wallpapers]
#
# How it stays safe:
#   1. Everything is copied to a temporary staging folder first. If anything
#      goes wrong there, your current configs are not touched.
#   2. Only then are your existing configs MOVED (not deleted) to a backup
#      folder and the new ones put in place.

# This check must come before any bash-only syntax (for example `sh install.sh`)
if [ -z "${BASH_VERSION:-}" ]; then
    echo "Please run this script with bash:  bash install.sh" >&2
    exit 1
fi

set -euo pipefail

ASSUME_YES=false
INSTALL_WALLPAPERS=false

for arg in "$@"; do
    case "$arg" in
        -y|--yes) ASSUME_YES=true ;;
        --wallpapers) INSTALL_WALLPAPERS=true ;;
        -h|--help)
            echo "Usage: $0 [--yes] [--wallpapers]"
            echo "  -y, --yes      Skip the confirmation prompt"
            echo "  --wallpapers   Also copy wallpapers/ to ~/Pictures/Wallpapers"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            echo "Try: $0 --help" >&2
            exit 1
            ;;
    esac
done

# Running with sudo would make $HOME point to /root and install into the wrong place
if [[ $EUID -eq 0 ]]; then
    echo "Run this script as your normal user, not as root or with sudo." >&2
    exit 1
fi

if [[ -z "${HOME:-}" || "$HOME" == "/" || ! -d "$HOME" ]]; then
    echo "HOME is not a valid directory (HOME='${HOME:-}'). Nothing was changed." >&2
    exit 1
fi

# Repository location (also works when the script is started through a symlink)
SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
DOTFILES_DIR="$(dirname -- "$SCRIPT_PATH")"

CONFIG_DIR="$HOME/.config"
BACKUP_ROOT="$CONFIG_DIR/dots-backup"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

# Applications this repository can install
APPS=(
    fastfetch
    kitty
    niri
    noctalia
)

# Which of them actually exist next to this script?
FOUND=()
for app in "${APPS[@]}"; do
    if [[ -d "$DOTFILES_DIR/$app" ]]; then
        FOUND+=("$app")
    else
        echo "Skipping $app: no '$app' folder next to install.sh."
    fi
done

if (( ${#FOUND[@]} == 0 )); then
    echo "Nothing to install: none of (${APPS[*]}) found in $DOTFILES_DIR" >&2
    exit 1
fi

echo "This will install: ${FOUND[*]}"
echo "Existing configs in $CONFIG_DIR are moved (not deleted) to: $BACKUP_ROOT/$TIMESTAMP"

if [[ "$ASSUME_YES" != true ]]; then
    printf 'Continue? [y/N] '
    answer=""
    read -r answer || true
    if [[ ! "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]; then
        echo "Aborted. Nothing was changed."
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Step 1: copy everything to a staging folder (touches nothing that exists yet)
# ---------------------------------------------------------------------------
mkdir -p "$CONFIG_DIR"
STAGE="$(mktemp -d "$CONFIG_DIR/.dots-staging.XXXXXX")"
BACKUP_DIR=""

cleanup() {
    local status=$?
    chmod -R u+rwX -- "$STAGE" 2>/dev/null || true
    rm -rf -- "$STAGE"
    if (( status != 0 )); then
        echo >&2
        echo "Installation did not finish (exit code $status)." >&2
        if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
            echo "Configs that were already replaced are saved in: $BACKUP_DIR" >&2
        else
            echo "Your existing configs were not modified." >&2
        fi
    fi
}
trap cleanup EXIT
# If interrupted (Ctrl+C, closed terminal) while preparing, leave through the
# cleanup handler above so the staging folder is removed and a message is shown.
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

echo "Preparing files..."
for app in "${FOUND[@]}"; do
    if [[ -L "$DOTFILES_DIR/$app" ]]; then
        # Symlinked app folder: copy its CONTENTS so the sed step below can
        # never write through the link into the source tree.
        mkdir -p -- "$STAGE/$app"
        cp -a -- "$DOTFILES_DIR/$app/." "$STAGE/$app/"
    else
        cp -a -- "$DOTFILES_DIR/$app" "$STAGE/"
    fi
done

# Replace the __HOME__ placeholder with the real home directory.
# Characters that sed treats specially (\ & |) are escaped first.
STAGED_SETTINGS="$STAGE/noctalia/settings.toml"
if [[ -f "$STAGED_SETTINGS" ]]; then
    home_escaped="$(printf '%s' "${HOME%/}" | sed -e 's/[\\&|]/\\&/g')"
    sed -i -e "s|__HOME__|${home_escaped}|g" "$STAGED_SETTINGS"
fi

# Optional: wallpapers (copied before the swap; never overwrites existing files)
if [[ "$INSTALL_WALLPAPERS" == true ]]; then
    WALLPAPER_SRC="$DOTFILES_DIR/wallpapers"
    WALLPAPER_DEST="$HOME/Pictures/Wallpapers"
    if [[ -d "$WALLPAPER_SRC" ]]; then
        mkdir -p "$WALLPAPER_DEST"
        copied=0
        while IFS= read -r -d '' file; do
            relative="${file#"$WALLPAPER_SRC"/}"
            destination="$WALLPAPER_DEST/$relative"
            if [[ ! -e "$destination" && ! -L "$destination" ]]; then
                mkdir -p "$(dirname -- "$destination")"
                cp -- "$file" "$destination"
                copied=$((copied + 1))
            fi
        done < <(find "$WALLPAPER_SRC" -type f -print0)
        echo "Wallpapers: $copied new file(s) copied to $WALLPAPER_DEST (existing files are never overwritten)."
    else
        echo "Skipping wallpapers: no wallpapers/ folder next to install.sh."
    fi
fi

# ---------------------------------------------------------------------------
# Step 2: back up what exists, then put the new configs in place
# ---------------------------------------------------------------------------
NEED_BACKUP=false
for app in "${FOUND[@]}"; do
    if [[ -e "$CONFIG_DIR/$app" || -L "$CONFIG_DIR/$app" ]]; then
        NEED_BACKUP=true
    fi
done

if [[ "$NEED_BACKUP" == true ]]; then
    # Pick a backup folder name that does not exist yet (two runs in one second)
    BACKUP_DIR="$BACKUP_ROOT/$TIMESTAMP"
    suffix=1
    while [[ -e "$BACKUP_DIR" || -L "$BACKUP_DIR" ]]; do
        BACKUP_DIR="$BACKUP_ROOT/$TIMESTAMP-$suffix"
        suffix=$((suffix + 1))
    done
    mkdir -p "$BACKUP_DIR"
fi

# The swap below only renames folders, so it takes a few milliseconds.
# Ignore interrupts from here on so it can never stop half-way.
trap '' INT TERM HUP

for app in "${FOUND[@]}"; do
    TARGET="$CONFIG_DIR/$app"
    if [[ -e "$TARGET" || -L "$TARGET" ]]; then
        # Renaming a directory requires owner-write on it (to update '..').
        # A read-only existing config would otherwise fail the backup move.
        if [[ -d "$TARGET" && ! -L "$TARGET" && ! -w "$TARGET" ]]; then
            chmod u+w -- "$TARGET"
        fi
        mv -- "$TARGET" "$BACKUP_DIR/"
        echo "Backed up existing $app config."
    fi
    if [[ -d "$STAGE/$app" && ! -L "$STAGE/$app" && ! -w "$STAGE/$app" ]]; then
        chmod u+w -- "$STAGE/$app"
    fi
    mv -- "$STAGE/$app" "$TARGET"
    echo "Installed $app."
done

echo
echo "Installation completed!"
if [[ "$NEED_BACKUP" == true ]]; then
    echo "Backups saved in: $BACKUP_DIR"
fi
echo "Next: install the Noctalia plugins and fonts (see the README), then run: noctalia config validate"
echo "Log out and back in, or restart your applications, to apply the changes."