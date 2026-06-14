#!/bin/bash

set -euo pipefail
shopt -s nullglob

# Base paths and files
BASEPATH="$(dirname "$(realpath "$0")")"
SOURCES_FILE="$BASEPATH/sources"
DUMMYFILENAME="xdummy.xml"
FINAL_MERGED_FILE="$BASEPATH/merged.xmltv"

# Generator info
GENERATOR_NAME=${GENERATOR_NAME:-"epgxml-merge-dummy"}
GENERATOR_URL=${GENERATOR_URL:-"https://github.com/mme89/epgxml-merge-dummy"}
DEFAULT_LANG=${DEFAULT_LANG:-"de"}

# Logging configuration
LOGFILE="${LOGFILE:-$BASEPATH/log/epgmerger.log}"
LOG_ROTATE_COUNT=${LOG_ROTATE_COUNT:-4}
DEBUG=${DEBUG:-false}

# Download configuration
WGET_TRIES=${WGET_TRIES:-3}
WGET_WAIT=${WGET_WAIT:-5}
WGET_CONNECT_TIMEOUT=${WGET_CONNECT_TIMEOUT:-10}
WGET_READ_TIMEOUT=${WGET_READ_TIMEOUT:-20}
WGET_DNS_TIMEOUT=${WGET_DNS_TIMEOUT:-10}

# Dummy EPG time slots
starttimes=("000000" "060000" "120000" "180000")
endtimes=("060000" "120000" "180000" "235900")

# Internal state
generated_files=()
LISTS=()
SED_INPLACE_ARGS=()
RUN_WORKDIR=""
MERGED_FILE=""

log() {
    local message logdir
    message="$(date '+%Y-%m-%d %H:%M:%S') - $*"
    logdir="$(dirname "$LOGFILE")"
    mkdir -p "$logdir" 2>/dev/null || true

    echo "$message"
    printf '%s\n' "$message" >> "$LOGFILE" 2>/dev/null || true
}

is_debug_enabled() {
    case "$DEBUG" in
        true|TRUE|True|1|yes|YES|Yes|on|ON|On)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

debug_log() {
    if is_debug_enabled; then
        log "DEBUG: $*"
    fi
}

trim_config_value() {
    local value="$1"
    value="${value//$'\r'/}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

init_sed_mode() {
    if sed --version >/dev/null 2>&1; then
        SED_INPLACE_ARGS=(-i)
    else
        SED_INPLACE_ARGS=(-i '')
    fi
}

sed_inplace() {
    sed "${SED_INPLACE_ARGS[@]}" "$@"
}

escape_sed_pattern() {
    local input="$1"
    local output=""
    local ch
    local i

    for ((i=0; i<${#input}; i++)); do
        ch="${input:i:1}"
        case "$ch" in
            "\\"|"|"|"."|"^"|"\$"|"*"|"["|"]"|"&")
                output+="\\$ch"
                ;;
            *)
                output+="$ch"
                ;;
        esac
    done

    printf '%s' "$output"
}

xml_escape_attr() {
    local value="$1"
    local output=""
    local ch
    local i

    for ((i=0; i<${#value}; i++)); do
        ch="${value:i:1}"
        case "$ch" in
            '&') output+="&amp;" ;;
            '"') output+="&quot;" ;;
            "'") output+="&apos;" ;;
            '<') output+="&lt;" ;;
            '>') output+="&gt;" ;;
            *) output+="$ch" ;;
        esac
    done

    printf '%s' "$output"
}

xml_escape_text() {
    local value="$1"
    local output=""
    local ch
    local i

    for ((i=0; i<${#value}; i++)); do
        ch="${value:i:1}"
        case "$ch" in
            '&') output+="&amp;" ;;
            '<') output+="&lt;" ;;
            '>') output+="&gt;" ;;
            *) output+="$ch" ;;
        esac
    done

    printf '%s' "$output"
}

escape_sed_replacement() {
    local input="$1"
    local output=""
    local ch
    local i

    for ((i=0; i<${#input}; i++)); do
        ch="${input:i:1}"
        case "$ch" in
            [\\\|\&])
                output+="\\$ch"
                ;;
            *)
                output+="$ch"
                ;;
        esac
    done

    printf '%s' "$output"
}

cleanup() {
    log "Cleaning up temporary files..."
    if [ -z "$RUN_WORKDIR" ] || [ ! -d "$RUN_WORKDIR" ]; then
        return
    fi

    log "Deleting temporary workspace $RUN_WORKDIR..."
    rm -rf "$RUN_WORKDIR"
    RUN_WORKDIR=""
    generated_files=()
}

trap cleanup EXIT

rotate_logs() {
    mkdir -p "$(dirname "$LOGFILE")"

    local rotated_log suffix
    for rotated_log in "$LOGFILE".[0-9]*; do
        suffix="${rotated_log#"$LOGFILE".}"
        if [[ "$suffix" =~ ^[0-9]+$ ]] && [ "$suffix" -ge "$LOG_ROTATE_COUNT" ]; then
            rm -f "$rotated_log"
        fi
    done

    if [ "$LOG_ROTATE_COUNT" -eq 0 ]; then
        : > "$LOGFILE"
        return
    fi

    if [ "$LOG_ROTATE_COUNT" -ge 2 ]; then
        for ((i=LOG_ROTATE_COUNT-1; i>=1; i--)); do
            if [ -f "$LOGFILE.$i" ]; then
                mv "$LOGFILE.$i" "$LOGFILE.$((i+1))"
            fi
        done
    fi

    if [ -s "$LOGFILE" ]; then
        mv "$LOGFILE" "$LOGFILE.1"
    fi

    : > "$LOGFILE"
}

log_header() {
    local ts
    local logdir
    local sep="============================================================"
    logdir="$(dirname "$LOGFILE")"
    mkdir -p "$logdir"
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    {
        echo "$sep"
        echo "EPG RUN START - $ts (PID $$)"
        echo "$sep"
    } | tee -a "$LOGFILE"
}

show_help() {
    local exit_code="${1:-0}"
    cat << EOF
Usage: $(basename "$0") [OPTION]

This script generates, downloads, processes, and merges EPG (Electronic Program Guide) XML files.
Requires wget, xmltv (tv_sort/tv_merge), gunzip, sed, awk, mktemp, perl, and XML::LibXML.

Options:
  --help         Show this help message and exit.
  -dummy         Generate EPG channels using dummy_channels.
  -filter        Apply filtering to the merged EPG file using patterns from filter_epg_patterns.
  -cutoff-date YYYYMMDD
                 Remove programme entries starting after this date (e.g., 20241231).
                 Cannot be used with -cutoff-days.
  -cutoff-days N
                 Remove programme entries starting after N days from today.
                 N must be a positive integer.
                 Cannot be used with -cutoff-date.

Files:
  - sources: File containing the list of EPG sources (URLs or file paths), located in the same directory as the script.
  - dummy_channels: File containing dummy channel definitions, located in the same directory as the script.
  - filter_epg_patterns: File containing patterns to filter out from the merged EPG file.

Environment Variables:
  - GENERATOR_NAME       Set custom generator name in merged EPG file. Default: "epgxml-merge-dummy"
  - GENERATOR_URL        Set custom generator URL in merged EPG file. Default: "https://github.com/mme89/epgxml-merge-dummy"
  - DEFAULT_LANG         Set default language code for EPG entries. Default: "de"
  - LOGFILE              Specify a custom log file location. Default: <script_dir>/log/epgmerger.log
  - LOG_ROTATE_COUNT     Number of rotated log backups to keep. Default: 4. Set to 0 to disable backups.
  - DEBUG                Enable debug logging. Set to "true" to enable.
  - WGET_TRIES           Number of download retry attempts. Must be >= 1. Default: 3
  - WGET_WAIT            Seconds to wait between retries. Must be >= 0. Default: 5
  - WGET_CONNECT_TIMEOUT Connection timeout in seconds. Must be >= 1. Default: 10
  - WGET_READ_TIMEOUT    Read timeout in seconds. Must be >= 1. Default: 20
  - WGET_DNS_TIMEOUT     DNS timeout in seconds. Must be >= 1. Default: 10
EOF
    trap - EXIT
    exit "$exit_code"
}

check_dependencies() {
    for cmd in wget tv_sort tv_merge gunzip sed awk mktemp perl; do
        if ! command -v "$cmd" &>/dev/null; then
            echo "Error: $cmd is not installed. Please install it and try again."
            exit 1
        fi
    done

    if ! perl -MXML::LibXML -e 1 >/dev/null 2>&1; then
        echo "Error: Perl module XML::LibXML is not installed. Please install it and try again."
        exit 1
    fi
}

init_workdir() {
    RUN_WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/epgmerger.XXXXXX")"
    MERGED_FILE="$RUN_WORKDIR/merged.xmltv"
    log "Using temporary workspace $RUN_WORKDIR"
}

validate_config() {
    if ! [[ "$LOG_ROTATE_COUNT" =~ ^[0-9]+$ ]]; then
        echo "Warning: LOG_ROTATE_COUNT='$LOG_ROTATE_COUNT' is invalid. Falling back to 4." >&2
        LOG_ROTATE_COUNT=4
    fi

    if ! [[ "$WGET_TRIES" =~ ^[1-9][0-9]*$ ]]; then
        echo "Warning: WGET_TRIES='$WGET_TRIES' is invalid. Falling back to 3." >&2
        WGET_TRIES=3
    fi

    if ! [[ "$WGET_WAIT" =~ ^[0-9]+$ ]]; then
        echo "Warning: WGET_WAIT='$WGET_WAIT' is invalid. Falling back to 5." >&2
        WGET_WAIT=5
    fi

    if ! [[ "$WGET_CONNECT_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
        echo "Warning: WGET_CONNECT_TIMEOUT='$WGET_CONNECT_TIMEOUT' is invalid. Falling back to 10." >&2
        WGET_CONNECT_TIMEOUT=10
    fi

    if ! [[ "$WGET_READ_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
        echo "Warning: WGET_READ_TIMEOUT='$WGET_READ_TIMEOUT' is invalid. Falling back to 20." >&2
        WGET_READ_TIMEOUT=20
    fi

    if ! [[ "$WGET_DNS_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
        echo "Warning: WGET_DNS_TIMEOUT='$WGET_DNS_TIMEOUT' is invalid. Falling back to 10." >&2
        WGET_DNS_TIMEOUT=10
    fi
}

load_sources() {
    if [ ! -f "$SOURCES_FILE" ]; then
        echo "Error: Sources file not found at $SOURCES_FILE."
        exit 1
    fi

    LISTS=()
    while IFS= read -r line || [ -n "$line" ]; do
        line="$(trim_config_value "$line")"
        [[ "$line" =~ ^# ]] && continue
        [ -z "$line" ] && continue
        LISTS+=("$line")
    done < "$SOURCES_FILE"

    debug_log "Loaded ${#LISTS[@]} source(s) from $SOURCES_FILE."
}

dummycreator() {
    local DUMMY_CHANNELS_FILE="$BASEPATH/dummy_channels"
    local default_lang_xml
    default_lang_xml="$(xml_escape_attr "$DEFAULT_LANG")"

    today=$(date +%Y%m%d)
    if tomorrow=$(date --date="+1 day" +%Y%m%d 2>/dev/null); then
        :
    elif tomorrow=$(date -v+1d +%Y%m%d 2>/dev/null); then
        :
    else
        log "Warning: Could not determine tomorrow's date. Using today instead for dummy EPG."
        tomorrow="$today"
    fi

    if [ ! -f "$DUMMY_CHANNELS_FILE" ]; then
        echo "Error: Dummy channels file not found at $DUMMY_CHANNELS_FILE."
        exit 1
    fi

    local numberofchannels=0
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        line="$(trim_config_value "$line")"
        [[ "$line" =~ ^# ]] && continue
        [ -z "$line" ] && continue
        numberofchannels=$((numberofchannels + 1))
    done < "$DUMMY_CHANNELS_FILE"

    if [ "$numberofchannels" -eq 0 ]; then
        echo "Error: Dummy channels file is empty or contains only comments. Please add at least one channel."
        exit 1
    fi

    log "Generating dummy EPG for $numberofchannels channels..."

    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<tv>'

        while IFS= read -r line || [ -n "$line" ]; do
            line="$(trim_config_value "$line")"
            [[ "$line" =~ ^# ]] && continue
            [ -z "$line" ] && continue

            IFS='|' read -r tvgid name title desc <<< "$line"
            tvgid="$(trim_config_value "$tvgid")"
            name="$(trim_config_value "${name:-}")"
            title="$(trim_config_value "${title:-}")"
            desc="$(trim_config_value "${desc:-}")"
            [ -z "$tvgid" ] && continue

            local tvgid_xml name_xml title_xml desc_xml
            tvgid_xml="$(xml_escape_attr "$tvgid")"
            name_xml="$(xml_escape_text "$name")"
            title_xml="$(xml_escape_text "$title")"
            desc_xml="$(xml_escape_text "$desc")"

            echo "    <channel id=\"$tvgid_xml\">"
            echo "        <display-name lang=\"$default_lang_xml\">$name_xml</display-name>"
            echo "    </channel>"

            for j in {0..3}; do
                echo "    <programme start=\"$today${starttimes[$j]} +0000\" stop=\"$today${endtimes[$j]} +0000\" channel=\"$tvgid_xml\">"
                echo "        <title lang=\"$default_lang_xml\">$title_xml</title>"
                echo "        <desc lang=\"$default_lang_xml\">$desc_xml</desc>"
                echo "    </programme>"
            done

            for j in {0..3}; do
                echo "    <programme start=\"$tomorrow${starttimes[$j]} +0000\" stop=\"$tomorrow${endtimes[$j]} +0000\" channel=\"$tvgid_xml\">"
                echo "        <title lang=\"$default_lang_xml\">$title_xml</title>"
                echo "        <desc lang=\"$default_lang_xml\">$desc_xml</desc>"
                echo "    </programme>"
            done
        done < "$DUMMY_CHANNELS_FILE"

        echo '</tv>'
    } >"$RUN_WORKDIR/$DUMMYFILENAME"

    generated_files+=("$RUN_WORKDIR/$DUMMYFILENAME")
}

fixall() {
    if [ ${#generated_files[@]} -eq 0 ]; then
        return
    fi

    for xml in "${generated_files[@]}"; do
        log "Fixing $xml..."
        sed_inplace "/<url>/d" "$xml"
        sed_inplace "s/lang=\"\"/lang=\"$DEFAULT_LANG\"/g" "$xml"
        sed_inplace "s/<display-name>/<display-name lang=\"$DEFAULT_LANG\">/g" "$xml"
    done
}

downloadepgs() {
    if [ ${#LISTS[@]} -eq 0 ]; then
        log "No sources configured in $SOURCES_FILE. Skipping source download/copy."
        return
    fi

    local INDEX=1
    for list in "${LISTS[@]}"; do
        if [[ $list == http* ]]; then
            log "Downloading $list..."
            local dir success attempt
            dir="$(mktemp -d "$RUN_WORKDIR/download.XXXXXX")"
            success=false

            for ((attempt=1; attempt<=WGET_TRIES; attempt++)); do
                log "Attempt ${attempt}/${WGET_TRIES}"
                if wget \
                    --tries=1 \
                    --retry-connrefused \
                    --retry-on-http-error=429,500,502,503,504 \
                    --connect-timeout="$WGET_CONNECT_TIMEOUT" \
                    --read-timeout="$WGET_READ_TIMEOUT" \
                    --dns-timeout="$WGET_DNS_TIMEOUT" \
                    -P "$dir" --content-disposition --trust-server-names "$list" >/dev/null 2>&1; then
                    log "Attempt ${attempt}/${WGET_TRIES} - success"
                    success=true
                    break
                fi
                log "Attempt ${attempt}/${WGET_TRIES} - failed"
                if (( attempt < WGET_TRIES )); then
                    sleep "$WGET_WAIT"
                fi
            done

            if [ "$success" != true ]; then
                log "Warning: Failed to download $list. Skipping this source."
                rmdir "$dir"
                INDEX=$((INDEX + 1))
                continue
            fi

            local files
            files=("$dir"/*)
            if [ ${#files[@]} -eq 0 ]; then
                log "Warning: No file downloaded from $list. Skipping this source."
                rmdir "$dir"
                INDEX=$((INDEX + 1))
                continue
            fi

            local file_index="$INDEX"
            local ext
            for file in "${files[@]}"; do
                ext=${file##*.}
                mv "$file" "$RUN_WORKDIR/$file_index.$ext"
                generated_files+=("$RUN_WORKDIR/$file_index.$ext")
                file_index=$((file_index + 1))
            done

            INDEX="$file_index"
            rmdir "$dir"
            continue
        else
            log "Processing local file $list..."
            if [ -f "$list" ]; then
                local source_name local_ext
                source_name="${list##*/}"
                if [[ "$source_name" == *.* ]]; then
                    local_ext="${source_name##*.}"
                else
                    local_ext="xml"
                fi

                cp "$list" "$RUN_WORKDIR/$INDEX.$local_ext"
                generated_files+=("$RUN_WORKDIR/$INDEX.$local_ext")
            else
                log "Warning: Local file $list not found. Skipping this source."
            fi
        fi
        INDEX=$((INDEX + 1))
    done
}

extractgz() {
    log "Extracting compressed files..."
    if [ ${#generated_files[@]} -eq 0 ]; then
        log "No generated files found to extract."
        return
    fi

    local extracted_any=false
    local ok_files=()
    local source_file output_file tmp_file

    for source_file in "${generated_files[@]}"; do
        if [[ "$source_file" == *.gz ]]; then
            if [ -f "$source_file" ]; then
                extracted_any=true
                output_file="${source_file%.gz}"
                tmp_file="$(mktemp "$RUN_WORKDIR/extracted.XXXXXX.xmltv")"

                if gunzip -c "$source_file" > "$tmp_file" 2>/dev/null && [ -s "$tmp_file" ]; then
                    mv "$tmp_file" "$output_file"
                    rm -f "$source_file"
                    ok_files+=("$output_file")
                else
                    log "Warning: Failed to extract $source_file. Dropping this file from merge."
                    rm -f "$tmp_file"
                fi
            else
                log "Warning: Compressed file not found: $source_file"
            fi
        else
            ok_files+=("$source_file")
        fi
    done

    if [ "$extracted_any" != true ]; then
        log "No compressed files found to extract."
    fi

    generated_files=("${ok_files[@]}")
}

sortall() {
    if [ ${#generated_files[@]} -eq 0 ]; then
        return
    fi

    local ok_files=()
    for xml in "${generated_files[@]}"; do
        log "Sorting $xml..."
        local sorted_tmp
        sorted_tmp="$(mktemp "$RUN_WORKDIR/sorted.XXXXXX.xmltv")"
        if tv_sort --by-channel --output "$sorted_tmp" "$xml" >/dev/null 2>&1 && [ -s "$sorted_tmp" ]; then
            mv "$sorted_tmp" "$xml"
            ok_files+=("$xml")
        else
            log "Warning: Failed to sort $xml. Dropping this file from merge."
            rm -f "$sorted_tmp"
        fi
    done
    generated_files=("${ok_files[@]}")
}

mergeall() {
    if [ ${#generated_files[@]} -eq 0 ]; then
        log "Error: No XML files to merge."
        return 1
    fi

    if [ ${#generated_files[@]} -eq 1 ]; then
        log "Only one XML file detected. Copying it to merged.xmltv..."
        cp -f "${generated_files[0]}" "$MERGED_FILE"
        return 0
    fi

    log "Initializing merged.xmltv with ${generated_files[0]}..."
    cp -f "${generated_files[0]}" "$MERGED_FILE"

    for xml in "${generated_files[@]:1}"; do
        log "Merging $xml into merged.xmltv..."
        local merge_tmp
        merge_tmp="$(mktemp "$RUN_WORKDIR/merged.XXXXXX.xmltv")"
        if tv_merge -i "$MERGED_FILE" -m "$xml" -o "$merge_tmp" >/dev/null 2>&1 && [ -s "$merge_tmp" ]; then
            mv "$merge_tmp" "$MERGED_FILE"
        else
            log "Warning: Failed to merge $xml. Skipping it and continuing."
            rm -f "$merge_tmp"
            continue
        fi
    done

    return 0
}

ensure_channels_in_merged() {
    local TEMP_FILE="$RUN_WORKDIR/merged.with-channels.xmltv"

    if [ ! -f "$MERGED_FILE" ]; then
        log "Merged file $MERGED_FILE not found for ensuring channels."
        return
    fi

    log "Ensuring all channels referenced by programmes exist in $MERGED_FILE..."

    local missing_count
    if ! missing_count=$(perl -MXML::LibXML -e '
        use strict;
        use warnings;

        my ($file, $out, $lang) = @ARGV;
        my $parser = XML::LibXML->new(no_blanks => 0);
        my $doc = $parser->parse_file($file);
        my $root = $doc->documentElement;
        die "Root element is not <tv>\n" unless $root && $root->nodeName eq "tv";

        my %existing = map { $_->getAttribute("id") => 1 } $root->findnodes("./channel[\@id]");
        my @missing;
        my %seen_missing;

        for my $programme ($root->findnodes(".//programme[\@channel]")) {
            my $channel = $programme->getAttribute("channel");
            next if $channel eq "";
            next if $existing{$channel} || $seen_missing{$channel};
            push @missing, $channel;
            $seen_missing{$channel} = 1;
        }

        if (!@missing) {
            print "0\n";
            exit 0;
        }

        my ($first_programme) = $root->findnodes("./programme[1]");
        for my $channel_id (@missing) {
            my $channel = $doc->createElement("channel");
            $channel->setAttribute(id => $channel_id);

            my $display_name = $doc->createElement("display-name");
            $display_name->setAttribute(lang => $lang) if defined $lang && $lang ne "";
            $display_name->appendTextNode($channel_id);
            $channel->appendChild($doc->createTextNode("\n    "));
            $channel->appendChild($display_name);
            $channel->appendChild($doc->createTextNode("\n  "));

            if ($first_programme) {
                $root->insertBefore($channel, $first_programme);
                $root->insertBefore($doc->createTextNode("\n  "), $first_programme);
            } else {
                $root->appendChild($doc->createTextNode("\n  "));
                $root->appendChild($channel);
            }
        }

        $root->appendChild($doc->createTextNode("\n")) unless $first_programme;
        open my $fh, ">:encoding(UTF-8)", $out or die "Cannot write $out: $!\n";
        print {$fh} $doc->toString(1);
        close $fh;
        print scalar(@missing), "\n";
    ' "$MERGED_FILE" "$TEMP_FILE" "$DEFAULT_LANG"); then
        log "Error: Failed to ensure channel definitions. Original file kept."
        rm -f "$TEMP_FILE"
        return
    fi

    if [ "$missing_count" -eq 0 ]; then
        log "All referenced channels already exist."
        return
    fi

    log "Adding ${missing_count} missing channel definition(s)."
    mv "$TEMP_FILE" "$MERGED_FILE"
    log "Missing channel definitions added."
}

fix_tv_tag() {
    local TEMP_FILE="$RUN_WORKDIR/merged.temp.xmltv"

    if [ ! -f "$MERGED_FILE" ]; then
        log "Merged file $MERGED_FILE not found for fixing TV tag."
        return
    fi

    log "Replacing <tv> tag with custom generator info..."

    if ! perl -MXML::LibXML -e '
        use strict;
        use warnings;

        my ($file, $out, $generator_name, $generator_url) = @ARGV;
        my $parser = XML::LibXML->new(no_blanks => 0);
        my $doc = $parser->parse_file($file);
        my $root = $doc->documentElement;
        die "Root element is not <tv>\n" unless $root && $root->nodeName eq "tv";

        $root->setAttribute("generator-info-name", $generator_name);
        $root->setAttribute("generator-info-url", $generator_url);

        open my $fh, ">:encoding(UTF-8)", $out or die "Cannot write $out: $!\n";
        print {$fh} $doc->toString(1);
        close $fh;
    ' "$MERGED_FILE" "$TEMP_FILE" "$GENERATOR_NAME" "$GENERATOR_URL"; then
        log "Error: Failed to update TV tag. Original file kept."
        rm -f "$TEMP_FILE"
        return
    fi

    if [ -s "$TEMP_FILE" ]; then
        mv "$TEMP_FILE" "$MERGED_FILE"
        log "TV tag updated successfully."
    else
        log "Error: Failed to update TV tag. Original file kept."
        rm -f "$TEMP_FILE"
    fi
}

filter_merged() {
    local PATTERNS_FILE="$BASEPATH/filter_epg_patterns"
    if [ ! -f "$PATTERNS_FILE" ]; then
        log "No filter patterns file found at $PATTERNS_FILE. Skipping filtering of merged file."
        return
    fi

    if [ -f "$MERGED_FILE" ]; then
        log "Filtering $MERGED_FILE using patterns from $PATTERNS_FILE..."
        while IFS= read -r pattern || [ -n "$pattern" ]; do
            pattern="$(trim_config_value "$pattern")"
            [[ "$pattern" =~ ^# ]] && continue
            [ -z "$pattern" ] && continue
            log "Removing pattern: $pattern"
            local escaped_pattern
            escaped_pattern=$(escape_sed_pattern "$pattern")
            sed_inplace "/<title/ s|$escaped_pattern||g" "$MERGED_FILE"
            sed_inplace "/<desc/ s|$escaped_pattern||g" "$MERGED_FILE"
        done < "$PATTERNS_FILE"
    else
        log "Merged file $MERGED_FILE not found for filtering."
    fi
}

filter_by_cutoff_date() {
    local cutoff_date="$1"
    local TEMP_FILE="$RUN_WORKDIR/merged.temp.xmltv"

    if [ ! -f "$MERGED_FILE" ]; then
        log "Merged file $MERGED_FILE not found for cutoff date filtering."
        return
    fi

    log "Applying cutoff date $cutoff_date to $MERGED_FILE..."

    if ! perl -MXML::LibXML -e '
        use strict;
        use warnings;

        my ($file, $out, $cutoff) = @ARGV;
        my $parser = XML::LibXML->new(no_blanks => 0);
        my $doc = $parser->parse_file($file);
        my $root = $doc->documentElement;
        die "Root element is not <tv>\n" unless $root && $root->nodeName eq "tv";

        for my $programme ($root->findnodes(".//programme")) {
            my $start = $programme->getAttribute("start");
            next unless defined $start && $start =~ /^([0-9]{8})/;
            next unless $1 gt $cutoff;
            $programme->parentNode->removeChild($programme);
        }

        open my $fh, ">:encoding(UTF-8)", $out or die "Cannot write $out: $!\n";
        print {$fh} $doc->toString(1);
        close $fh;
    ' "$MERGED_FILE" "$TEMP_FILE" "$cutoff_date"; then
        log "Error: XML cutoff filtering failed. Original file kept."
        rm -f "$TEMP_FILE"
        return
    fi

    if [ -s "$TEMP_FILE" ]; then
        mv "$TEMP_FILE" "$MERGED_FILE"
        log "Cutoff date filtering complete."
    else
        log "Error: XML cutoff filtering produced an empty file. Original file kept."
        rm -f "$TEMP_FILE"
    fi
}

backup_existing_merged() {
    local backup_file="$BASEPATH/merged_backup.xmltv"

    if [ -f "$backup_file" ]; then
        log "Deleting existing backup file $backup_file..."
        rm -f "$backup_file"
    fi

    if [ -f "$FINAL_MERGED_FILE" ]; then
        log "Creating a new backup for merged.xmltv..."
        mv "$FINAL_MERGED_FILE" "$backup_file"
    else
        log "No existing merged.xmltv to back up."
    fi
}

publish_merged() {
    if [ ! -s "$MERGED_FILE" ]; then
        log "Error: Merged file $MERGED_FILE not found or empty. Nothing to publish."
        return 1
    fi

    backup_existing_merged
    log "Publishing final merged.xmltv..."
    mv "$MERGED_FILE" "$FINAL_MERGED_FILE"
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
                if [[ "${2:-}" =~ ^[0-9]{8}$ ]]; then
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
                if [[ "${2:-}" =~ ^[1-9][0-9]*$ ]]; then
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
                show_help 1
                ;;
        esac
    done

    validate_config
    rotate_logs
    log_header

    if [[ -n "$CUTOFF_DAYS" ]]; then
        if CUTOFF_DATE=$(date --date="+${CUTOFF_DAYS} days" +%Y%m%d 2>/dev/null); then
             :
        else
             if CUTOFF_DATE=$(date -v+"${CUTOFF_DAYS}"d +%Y%m%d 2>/dev/null); then
                 :
             else
                 echo "Error: Cannot determine correct syntax for date command to calculate future date." >&2
                 exit 1
             fi
        fi
        log "Calculated cutoff date: $CUTOFF_DATE (${CUTOFF_DAYS} days from today)"
    fi

    if [[ -n "$CUTOFF_DATE" ]]; then
        local today_val
        today_val=$(date +%Y%m%d)
        if [[ "$CUTOFF_DATE" < "$today_val" ]]; then
            log "Warning: cutoff date $CUTOFF_DATE is in the past. All programmes may be removed."
        fi
    fi

    log "Starting EPG processing script..."
    debug_log "Flags: dummy=$DUMMY filter=$FILTER cutoff_date=${CUTOFF_DATE:-none}"
    debug_log "Config: logfile=$LOGFILE rotate_count=$LOG_ROTATE_COUNT default_lang=$DEFAULT_LANG"
    init_sed_mode
    check_dependencies
    load_sources
    init_workdir

    if [[ "$DUMMY" == true ]]; then
        dummycreator
    fi

    downloadepgs
    extractgz
    fixall
    sortall
    if ! mergeall; then
        log "Merge step failed. Aborting remaining post-merge steps."
        return 1
    fi
    ensure_channels_in_merged
    fix_tv_tag

    if [[ "$FILTER" == true ]]; then
        filter_merged
    fi

    if [[ -n "$CUTOFF_DATE" ]]; then
        filter_by_cutoff_date "$CUTOFF_DATE"
    fi

    publish_merged

    trap - EXIT
    cleanup
    log "EPG processing complete!"
}

main "$@"
