#!/bin/bash
# Installs the fuses in this repository into DaVinci Resolve's Fusion Fuses
# directory. Symlinks by default so edits here take effect on the next Resolve
# restart without reinstalling; pass --copy for a real copy instead.

set -euo pipefail

MODE="symlink"
FORCE="no"
for arg in "$@"; do
	case "$arg" in
		--copy)    MODE="copy" ;;
		--symlink) MODE="symlink" ;;
		--force)   FORCE="yes" ;;
		*)
			echo "usage: $0 [--symlink|--copy] [--force]" >&2
			exit 1
			;;
	esac
done

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$(uname -s)" in
	Darwin)
		DEST="$HOME/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Fuses"
		;;
	Linux)
		DEST="$HOME/.local/share/DaVinciResolve/Fusion/Fuses"
		;;
	*)
		echo "unsupported platform: $(uname -s)" >&2
		exit 1
		;;
esac

mkdir -p "$DEST"

shopt -s nullglob
FUSES=("$REPO"/Fuses/*.fuse)
if [ ${#FUSES[@]} -eq 0 ]; then
	echo "no .fuse files found in $REPO/Fuses" >&2
	exit 1
fi

for fuse in "${FUSES[@]}"; do
	name="$(basename "$fuse")"
	target="$DEST/$name"

	# Don't silently clobber a fuse we didn't put there. A symlink already
	# pointing into this repository is ours to replace; anything else needs
	# --force so an unrelated file of the same name survives.
	if [ -L "$target" ]; then
		existing="$(readlink "$target")"
		case "$existing" in
			"$REPO"/*) ;;
			*)
				if [ "$FORCE" = "no" ]; then
					echo "refusing to replace $target (symlink to $existing); pass --force" >&2
					exit 1
				fi
				;;
		esac
	elif [ -e "$target" ]; then
		if [ "$FORCE" = "no" ]; then
			echo "refusing to replace existing file $target; pass --force" >&2
			exit 1
		fi
	fi

	rm -f "$target"

	if [ "$MODE" = "symlink" ]; then
		ln -s "$fuse" "$target"
	else
		cp "$fuse" "$target"
	fi

	echo "installed $name -> $target"
done

echo
echo "Restart Resolve, then find the tool under Fuses > Metadata > Aperture Probe."
