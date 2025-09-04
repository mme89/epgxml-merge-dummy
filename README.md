# epgxml-merge-dummy

The epgmerger.sh script is designed to process, merge, and manage Electronic Program Guide (EPG) XML files.
It automates tasks such as downloading EPG files, generating dummy EPG entries, sorting, merging, and cleaning up temporary files.

**Requirements**

- Linux with: `wget`, `xmltv` (tv_sort, tv_merge), `gzip`, `sed`, `awk`
- Install on Debian/Ubuntu:
  ```
  sudo apt install wget xmltv gzip sed gawk
  ```
  Notes:
  - `tv_sort` and `tv_merge` come with the `xmltv` package.
  - On systems without GNU sed/awk, install them or adjust in-place edits accordingly.

## Features

- EPG File Management:
  - Download EPG files from URLs or process local files specified in sources
  - Extract and process compressed .gz EPG files
  - Automatically sort and merge multiple EPG files
  - If only one source is provided, it is copied to `merged.xmltv`
- Robust fetching and logging:
  - Resilient downloads with retries and per-attempt logging (success/failed per try)
  - Continues processing remaining sources even if some fail
- Dummy EPG Creation:
  - Generate a dummy EPG using channel definitions from dummy_channels (optional with -dummy flag)
- Filter EPG Entries:
  - Apply filtering to the merged EPG file using patterns from filter_epg_patterns (optional with -filter flag)
- Cutoff Date Filtering:
  - Remove EPG entries starting after a specific date (optional with -cutoff-date or -cutoff-days flags)
- Channel Consistency:
  - Ensures all `<programme>` channel references have corresponding `<channel id>` entries
  - Any missing channel definitions are auto-added at the top, before the first programme
- Logging:
  - Log output is displayed in the terminal and written to a log file simultaneously
  - Custom log file location can be specified with the LOGFILE environment variable
  - In-script log rotation: keeps latest 5 logs by default (current + 4 backups) and adds a clear run separator

## Running the Script

```
./epgmerger.sh [OPTION]
```

Examples

```
# Basic run using entries from the sources file
./epgmerger.sh

# Generate dummy channels from dummy_channels and filter titles/descriptions
./epgmerger.sh -dummy -filter

# Keep programmes only up to a fixed date
./epgmerger.sh -cutoff-date 20251231

# Keep programmes only up to N days from today
./epgmerger.sh -cutoff-days 7
```

## Options

- `-dummy`: Generate dummy EPG using dummy_channels
- `-filter`: Apply filtering to the merged EPG file using patterns from filter_epg_patterns
- `-cutoff-date YYYYMMDD`: Remove programme entries starting after this date (e.g., 20241231). Cannot be used with -cutoff-days.
- `-cutoff-days N`: Remove programme entries starting N days after today. Cannot be used with -cutoff-date.
- `--help`: Show help information

## Environment Variables

- `DEBUG=true`: Enable debug logging
- `LOGFILE`: Specify a custom log file location (defaults to the script directory)
- `LOG_ROTATE_COUNT`: Number of rotated backups to keep (default: 4). Total kept logs = current + this number.
- Download retry tuning (defaults shown):
  - `WGET_TRIES` (3): Number of attempts per source
  - `WGET_WAIT` (5): Seconds to wait between attempts
  - `WGET_CONNECT_TIMEOUT` (10): Connection timeout seconds
  - `WGET_READ_TIMEOUT` (20): Read timeout seconds
  - `WGET_DNS_TIMEOUT` (10): DNS resolution timeout seconds

Example override for a run:

```
WGET_TRIES=5 WGET_WAIT=10 LOG_ROTATE_COUNT=6 ./epgmerger.sh
```

## Sources file

Define your inputs in `sources` (one per line). Lines starting with `#` are comments.

Examples:

```
# Remote XMLTV files
https://example.com/guide_a.xml
https://example.com/guide_b.xml.gz

# Local files
/absolute/path/to/local_epg1.xml
/absolute/path/to/local_epg2.xml
```

## File Structure

- `sources`: List of EPG file sources (URLs or local file paths)
- `dummy_channels`: Definitions for dummy EPG channels and programs
- `filter_epg_patterns`: Patterns to filter out from the merged EPG file
- `merged.xmltv`: The final merged EPG file
- `merged_backup.xmltv`: Backup of the most recent merged EPG
- `epgmerger.log`: Default log file (unless specified otherwise)

## Output details

- `merged.xmltv` is produced at the repository root
- During processing:
  - Sources are downloaded or copied locally, extracted if `.gz`, then sorted per channel
  - Files are merged incrementally using `tv_merge`
  - Any missing `<channel>` definitions for referenced programmes are added at the top
  - Optional filtering and cutoff-date pruning are applied
  - Temporary files are cleaned up automatically
  - Logs are rotated at the start of each run:
    - `epgmerger.log` (current), `epgmerger.log.1`, `epgmerger.log.2`, ... up to `LOG_ROTATE_COUNT`
    - Each run begins with a separator and timestamped header

##

This script combines two repos from yurividal

- [mergexmlepg](https://github.com/yurividal/mergexmlepg)
- [dummyepgxml](https://github.com/yurividal/dummyepgxml)