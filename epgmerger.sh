#!/bin/bash

set -euo pipefail

BASEPATH="$(dirname "$(realpath "$0")")"
LOGFILE="${LOGFILE:-$BASEPATH/epgmerger.log}"

DUMMYFILENAME="xdummy.xml"
SOURCES_FILE="$BASEPATH/sources"
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
  -dummy         Generate EPG channels using dummy_channels.
  -filter        Apply filtering to the merged EPG file using patterns from filter_epg_patterns.
  -cutoff-date YYYYMMDD
                 Remove programme entries starting after this date (e.g., 20241231).
                 Cannot be used with -cutoff-days.
  -cutoff-days N
                 Remove programme entries starting N days after today.
                 Cannot be used with -cutoff-date.

Files:
  - sources: File containing the list of EPG sources (URLs or file paths), located in the same directory as the script.
  - dummy_channels: File containing dummy channel definitions, located in the same directory as the script.
  - filter_epg_patterns: File containing patterns to filter out from the merged EPG file.

Environment Variables:
  - DEBUG=true   Enable debug logging.
  - LOGFILE      Specify a custom log file location. Defaults to the script's folder.
EOF
    trap - EXIT
    exit 0
}

check_dependencies() {
    for cmd in wget tv_sort tv_merge gunzip sed awk; do
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
    local DUMMY_CHANNELS_FILE="$BASEPATH/dummy_channels"

    today=$(date +%Y%m%d)
    tomorrow=$(date --date="+1 day" +%Y%m%d)

    if [ ! -f "$DUMMY_CHANNELS_FILE" ]; then
        echo "Error: Dummy channels file not found at $DUMMY_CHANNELS_FILE."
        exit 1
    fi

    local numberofchannels
    numberofchannels=$(grep -v '^[[:space:]]*#' "$DUMMY_CHANNELS_FILE" | grep -v '^[[:space:]]*$' | wc -l)

    if [ "$numberofchannels" -eq 0 ]; then
        echo "Error: Dummy channels file is empty or contains only comments. Please add at least one channel."
        exit 1
    fi

    log "Generating dummy EPG for $numberofchannels channels..."

    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<tv generator-info-name="dummy" generator-info-url="https://dummy.com/">'

        while IFS='|' read -r tvgid name title desc; do
            [[ "$tvgid" =~ ^[[:space:]]*# ]] && continue
            [ -z "$tvgid" ] && continue

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
    if [ ${#generated_files[@]} -eq 0 ]; then
        echo "Error: No XML files to merge."
        return
    fi

    if [ ${#generated_files[@]} -eq 1 ]; then
        log "Only one XML file detected. Copying it to merged.xmltv..."
        cp -f "${generated_files[0]}" "$BASEPATH/merged.xmltv"
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
}

ensure_channels_in_merged() {
    local MERGED_FILE="$BASEPATH/merged.xmltv"
    local TEMP_FILE="$BASEPATH/merged.with-channels.xmltv"

    if [ ! -f "$MERGED_FILE" ]; then
        log "Merged file $MERGED_FILE not found for ensuring channels."
        return
    fi

    log "Ensuring all channels referenced by programmes exist in $MERGED_FILE..."

    local EXISTING_CH="$BASEPATH/.existing_channels.txt"
    local REFERENCED_CH="$BASEPATH/.referenced_channels.txt"
    local MISSING_CH="$BASEPATH/.missing_channels.txt"

    grep -oE '<channel[^>]*id="[^"]+"' "$MERGED_FILE" \
        | sed -E 's/.*id="([^"]+)"/\1/' \
        | sort -u > "$EXISTING_CH" || true

    grep -oE '<programme[^>]*channel="[^"]+"' "$MERGED_FILE" \
        | sed -E 's/.*channel="([^"]+)"/\1/' \
        | sort -u > "$REFERENCED_CH" || true

    comm -13 "$EXISTING_CH" "$REFERENCED_CH" > "$MISSING_CH" || true

    if [ ! -s "$MISSING_CH" ]; then
        log "All referenced channels already exist."
        rm -f "$EXISTING_CH" "$REFERENCED_CH" "$MISSING_CH"
        return
    fi

    local missing_count
    missing_count=$(wc -l < "$MISSING_CH" | tr -d ' ')
    log "Adding ${missing_count} missing channel definition(s)."

    local MISSING_XML="$BASEPATH/.missing_channels.xml"
    : > "$MISSING_XML"
    while IFS= read -r ch; do
        [ -z "$ch" ] && continue
        printf '  <channel id="%s">\n' "$ch" >> "$MISSING_XML"
        printf '      <display-name lang="de">%s</display-name>\n' "$ch" >> "$MISSING_XML"
        printf '  </channel>\n' >> "$MISSING_XML"
    done < "$MISSING_CH"

    local prog_line
    prog_line=$(grep -n '<programme' "$MERGED_FILE" | head -n 1 | cut -d: -f1 || true)

    if [ -n "$prog_line" ]; then
        awk -v p="$prog_line" -v mx="$MISSING_XML" '
            NR==p {
                while ((getline l < mx) > 0) print l;
                close(mx)
            }
            { print }
        ' "$MERGED_FILE" > "$TEMP_FILE"
    else
        {
            sed '$d' "$MERGED_FILE"
            cat "$MISSING_XML"
            echo '</tv>'
        } > "$TEMP_FILE"
    fi

    mv "$TEMP_FILE" "$MERGED_FILE"
    rm -f "$EXISTING_CH" "$REFERENCED_CH" "$MISSING_CH" "$MISSING_XML"
    log "Missing channel definitions added."
}

filter_merged() {
    local PATTERNS_FILE="$BASEPATH/filter_epg_patterns"
    local MERGED_FILE="$BASEPATH/merged.xmltv"
    if [ ! -f "$PATTERNS_FILE" ]; then
         log "No filter patterns file found at $PATTERNS_FILE. Skipping filtering of merged file."
         return
    fi

    if [ -f "$MERGED_FILE" ]; then
        log "Filtering $MERGED_FILE using patterns from $PATTERNS_FILE..."
        while IFS= read -r pattern || [ -n "$pattern" ]; do
             [[ "$pattern" =~ ^[[:space:]]*# ]] && continue
             [ -z "$pattern" ] && continue
             log "Removing pattern: $pattern"
             sed -i "/<title/ s|$pattern||g" "$MERGED_FILE"
             sed -i "/<desc/ s|$pattern||g" "$MERGED_FILE"
        done < "$PATTERNS_FILE"
    else
      log "Merged file $MERGED_FILE not found for filtering."
    fi
}

filter_by_cutoff_date() {
    local cutoff_date="$1"
    local MERGED_FILE="$BASEPATH/merged.xmltv"
    local TEMP_FILE="$BASEPATH/merged.temp.xmltv"

    if [ ! -f "$MERGED_FILE" ]; then
        log "Merged file $MERGED_FILE not found for cutoff date filtering."
        return
    fi

    log "Applying cutoff date $cutoff_date to $MERGED_FILE..."

    awk -v cutoff="$cutoff_date" '
    BEGIN { in_prog = 0; keep_prog = 1; buffer = ""; }
    /<programme / {
        in_prog = 1;
        start_attr_line = $0;
        match(start_attr_line, /start="([0-9]{8})/);
        start_date = substr(start_attr_line, RSTART + 7, 8);

        if (start_date > cutoff) {
            keep_prog = 0;
            buffer = "";
        } else {
            keep_prog = 1;
            buffer = $0 ORS;
        }
        next;
    }
    /<\/programme>/ {
        if (in_prog && keep_prog) {
            buffer = buffer $0 ORS;
            printf "%s", buffer;
        }
        in_prog = 0;
        keep_prog = 1;
        buffer = "";
        next;
    }
    {
        if (in_prog && keep_prog) {
            buffer = buffer $0 ORS;
        } else if (!in_prog) {
            print $0;
        }
    }
    ' "$MERGED_FILE" > "$TEMP_FILE"

    if [ -s "$TEMP_FILE" ]; then
        mv "$TEMP_FILE" "$MERGED_FILE"
        log "Cutoff date filtering complete."
    else
        log "Error: awk filtering produced an empty file. Original file kept."
        rm -f "$TEMP_FILE"
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
    local FILTER=false
    local DUMMY=false
    local CUTOFF_DATE=""
    local CUTOFF_DAYS=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            --help)
                show_help
                ;;
            -dummy)
                DUMMY=true
                shift
                ;;
            -filter)
                FILTER=true
                shift
                ;;
            -cutoff-date)
                if [[ -n "$CUTOFF_DAYS" ]]; then
                    echo "Error: Cannot use -cutoff-date and -cutoff-days together." >&2
                    exit 1
                fi
                if [[ -n "$2" && "$2" =~ ^[0-9]{8}$ ]]; then
                    CUTOFF_DATE="$2"
                    shift
                    shift
                else
                    echo "Error: -cutoff-date requires a date in YYYYMMDD format." >&2
                    exit 1
                fi
                ;;
            -cutoff-days)
                if [[ -n "$CUTOFF_DATE" ]]; then
                     echo "Error: Cannot use -cutoff-date and -cutoff-days together." >&2
                     exit 1
                fi
                if [[ -n "$2" && "$2" =~ ^[0-9]+$ ]]; then
                    CUTOFF_DAYS="$2"
                    shift
                    shift
                else
                    echo "Error: -cutoff-days requires a positive integer number of days." >&2
                    exit 1
                fi
                ;;
            *)
                echo "Unknown option: $1" >&2
                show_help
                ;;
        esac
    done

    if [[ -n "$CUTOFF_DAYS" ]]; then
        if date --version >/dev/null 2>&1 ; then
             CUTOFF_DATE=$(date --date="+${CUTOFF_DAYS} days" +%Y%m%d)
        else
             if date -v+${CUTOFF_DAYS}d +%Y%m%d >/dev/null 2>&1 ; then
                 CUTOFF_DATE=$(date -v+${CUTOFF_DAYS}d +%Y%m%d)
             else
                 echo "Error: Cannot determine correct syntax for date command to calculate future date." >&2
                 exit 1
             fi
        fi
        log "Calculated cutoff date: $CUTOFF_DATE (${CUTOFF_DAYS} days from today)"
    fi

    log "Starting EPG processing script..."
    check_dependencies
    backup_existing_merged

    if [[ "$DUMMY" == true ]]; then
        dummycreator
    fi

    downloadepgs
    extractgz
    fixall
    sortall
    mergeall
    ensure_channels_in_merged

    if [[ "$FILTER" == true ]]; then
        filter_merged
    fi

    if [[ -n "$CUTOFF_DATE" ]]; then
        filter_by_cutoff_date "$CUTOFF_DATE"
    fi

    cleanup
    log "EPG processing complete!"
}

main "$@"