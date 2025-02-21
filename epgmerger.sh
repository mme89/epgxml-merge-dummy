#!/bin/bash

set -euo pipefail

BASEPATH="$(dirname "$(realpath "$0")")"
LOGFILE="${LOGFILE:-$BASEPATH/epgmerger.log}"
exec > "$LOGFILE" 2>&1

DUMMYFILENAME="xdummy.xml"
SOURCES_FILE="$BASEPATH/sources.txt"
DEBUG=${DEBUG:-false}

starttimes=("000000" "060000" "120000" "180000")
endtimes=("060000" "120000" "180000" "235900")

generated_files=()

log() {
    local message
    message="$(date '+%Y-%m-%d %H:%M:%S') - $@"
    echo "$message" | tee -a "$LOGFILE"
}

cleanup() {
    log "Cleaning up temporary files..."
    for file in "${generated_files[@]}"; do
        log "Deleting $file..."
        rm -f "$file"
    done
    generated_files=()
}

trap cleanup EXIT

show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTION]

This script generates, downloads, processes, and merges EPG (Electronic Program Guide) XML files.

Options:
  --help         Show this help message and exit.
  -dummy         Generate EPG channels using dummy_channels.txt.

Files:
  - sources: File containing the list of EPG sources (URLs or file paths), located in the same directory as the script.
  - dummy_channels: File containing dummy channel definitions, located in the same directory as the script.

Environment Variables:
  - DEBUG=true   Enable debug logging.
  - LOGFILE      Specify a custom log file location. Defaults to the script's folder.
EOF
    exit 0
}

check_dependencies() {
    for cmd in wget tv_sort tv_merge gunzip sed; do
        if ! command -v "$cmd" &>/dev/null; then
            echo "Error: $cmd is not installed. Please install it and try again."
            exit 1
        fi
    done
}

if [ ! -f "$SOURCES_FILE" ]; then
    echo "Error: Sources file not found at $SOURCES_FILE."
    exit 1
fi

LISTS=()
while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [ -z "$line" ] && continue
    LISTS+=("$line")
done < "$SOURCES_FILE"

dummycreator() {
    local DUMMY_CHANNELS_FILE="$BASEPATH/dummy_channels.txt"

    today=$(date +%Y%m%d)
    tomorrow=$(date --date="+1 day" +%Y%m%d)

    if [ ! -f "$DUMMY_CHANNELS_FILE" ]; then
        echo "Error: Dummy channels file not found at $DUMMY_CHANNELS_FILE."
        exit 1
    fi

    local numberofchannels
    numberofchannels=$(grep -v '^#' "$DUMMY_CHANNELS_FILE" | wc -l)

    if [ "$numberofchannels" -eq 0 ]; then
        echo "Error: Dummy channels file is empty or contains only comments. Please add at least one channel."
        exit 1
    fi

    log "Generating dummy EPG for $numberofchannels channels..."

    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<tv generator-info-name="dummy" generator-info-url="https://dummy.com/">'

        while IFS='|' read -r tvgid name title desc; do
            [[ "$tvgid" == \#* ]] && continue

            echo "    <channel id=\"$tvgid\">"
            echo "        <display-name lang=\"de\">$name</display-name>"
            echo "    </channel>"

            for j in {0..3}; do
                echo "    <programme start=\"$today${starttimes[$j]} +0000\" stop=\"$today${endtimes[$j]} +0000\" channel=\"$tvgid\">"
                echo "        <title lang=\"de\">$title</title>"
                echo "        <desc lang=\"de\">$desc</desc>"
                echo "    </programme>"
            done

            for j in {0..3}; do
                echo "    <programme start=\"$tomorrow${starttimes[$j]} +0000\" stop=\"$tomorrow${endtimes[$j]} +0000\" channel=\"$tvgid\">"
                echo "        <title lang=\"de\">$title</title>"
                echo "        <desc lang=\"de\">$desc</desc>"
                echo "    </programme>"
            done
        done < "$DUMMY_CHANNELS_FILE"

        echo '</tv>'
    } >"$BASEPATH/$DUMMYFILENAME"

    generated_files+=("$BASEPATH/$DUMMYFILENAME")
}

fixall() {
    for xml in "${generated_files[@]}"; do
        log "Fixing $xml..."
        sed -i "/<url>/d" "$xml"
        sed -i "s/lang=\"\"/lang=\"de\"/g" "$xml"
        sed -i "s/<display-name>/<display-name lang=\"de\">/g" "$xml"
    done
}

downloadepgs() {
    local INDEX=1
    for list in "${LISTS[@]}"; do
        if [[ $list == http* ]]; then
            log "Downloading $list..."
            local dir
            dir="$(mktemp -d)"
            wget -q --show-progress -P "$dir" --content-disposition --trust-server-names "$list"
            for file in "$dir"/*; do
                ext=${file##*.}
                mv "$file" "$BASEPATH/$INDEX.$ext"
                generated_files+=("$BASEPATH/$INDEX.$ext")
            done
            rmdir "$dir"
        else
            log "Processing local file $list..."
            cp "$list" "$BASEPATH/$INDEX.xml"
            generated_files+=("$BASEPATH/$INDEX.xml")
        fi
        ((INDEX++))
    done
}

extractgz() {
    log "Extracting compressed files..."
    if ls "$BASEPATH"/*.gz 1>/dev/null 2>&1; then
        for i in "${!generated_files[@]}"; do
            if [[ "${generated_files[$i]}" == *.gz ]]; then
                generated_files[$i]="${generated_files[$i]%.gz}"
            fi
        done
        gunzip -f "$BASEPATH"/*.gz
    else
        log "No compressed files found to extract."
    fi
}

sortall() {
    for xml in "${generated_files[@]}"; do
        log "Sorting $xml..."
        tv_sort --by-channel --output "$xml" "$xml"
    done
}

mergeall() {
    if [ ${#generated_files[@]} -lt 2 ]; then
        echo "Error: Not enough XML files to merge."
        return
    fi

    log "Merging ${generated_files[0]} with ${generated_files[1]}..."
    tv_merge -i "${generated_files[0]}" -m "${generated_files[1]}" -o "$BASEPATH/merged.xmltv" || {
        echo "Error: Failed to merge files."
        return
    }

    for xml in "${generated_files[@]:2}"; do
        log "Merging $xml..."
        tv_merge -i "$BASEPATH/merged.xmltv" -m "$xml" -o "$BASEPATH/merged.xmltv" || {
            echo "Error: Failed to merge $xml."
            return
        }
    done

    filter_merged
}

filter_merged() {
    local PATTERNS_FILE="$BASEPATH/filter_epg_patterns.txt"
    if [ ! -f "$PATTERNS_FILE" ]; then
         log "No filter patterns file found at $PATTERNS_FILE. Skipping filtering of merged file."
         return
    fi

    if [ -f "$BASEPATH/merged.xmltv" ]; then
        log "Filtering merged.xmltv using patterns from $PATTERNS_FILE..."
        while IFS= read -r pattern || [ -n "$pattern" ]; do
             [[ "$pattern" =~ ^[[:space:]]*# ]] && continue
             [ -z "$pattern" ] && continue
             log "Removing pattern: $pattern"
             sed -i "/<title/ s|$pattern||g" "$BASEPATH/merged.xmltv"
             sed -i "/<desc/ s|$pattern||g" "$BASEPATH/merged.xmltv"
        done < "$PATTERNS_FILE"
    fi
}

backup_existing_merged() {
    local backup_file="$BASEPATH/merged_backup.xmltv"

    if [ -f "$backup_file" ]; then
        log "Deleting existing backup file $backup_file..."
        rm -f "$backup_file"
    fi

    if [ -f "$BASEPATH/merged.xmltv" ]; then
        log "Creating a new backup for merged.xmltv..."
        mv "$BASEPATH/merged.xmltv" "$backup_file"
    else
        log "No existing merged.xmltv to back up."
    fi
}

main() {
    if [[ "${1:-}" == "--help" ]]; then
        show_help
    fi

    log "Starting EPG processing script..."
    check_dependencies
    backup_existing_merged

    if [[ "${1:-}" == "-dummy" ]]; then
        dummycreator
    fi

    downloadepgs
    extractgz
    fixall
    sortall
    mergeall
    cleanup
    log "EPG processing complete!"
}

main "$@"