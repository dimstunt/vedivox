#!/bin/sh
# Keeps a command's old name working after the rename to Vedivox: a link
# <old> → <new> next to the new binary.
#
#   cli_alias.sh <bin dir> <new name> <old name>
#
# The link is made only where the old name is free or already ours: a link to
# the new binary, or the binary an install before the rename put there (every
# one of those carries the old link scheme). Anything else under that name
# belongs to another program and stays; one line says the alias was not made.
# Always exits 0: a missing alias must not fail an install.
set -eu

dir=$1 new=$2 old=$3
path="$dir/$old"

if [ -L "$path" ]; then
    link=$(readlink "$path")
    if [ "$link" != "$new" ] && [ "$link" != "$dir/$new" ]; then
        echo "! $old is not an alias of $new: $path is a link to $link, left as it is"
        exit 0
    fi
elif [ -e "$path" ]; then
    if ! LC_ALL=C grep -aq 'vox://meeting/' "$path"; then
        echo "! $old is not an alias of $new: $path belongs to another program, left as it is"
        exit 0
    fi
fi

rm -f "$path"
ln -s "$new" "$path"
echo "✓ $old → $new (the old name keeps working)"
