# epgxml-merge-dummy

[![Last Commit](https://img.shields.io/github/last-commit/mme89/epgxml-merge-dummy?style=for-the-badge)](https://github.com/mme89/epgxml-merge-dummy)
[![License](https://img.shields.io/github/license/mme89/epgxml-merge-dummy?style=for-the-badge)](https://github.com/mme89/epgxml-merge-dummy/blob/main/LICENSE)

`epgmerger.sh` builds a single XMLTV/EPG file from remote URLs, local XMLTV files, optional dummy channels, and a few cleanup passes.

It is meant for small home-server or automation workflows where you want one reliable `merged.xmltv` output from several guide sources.

## What It Does

- Downloads XMLTV sources from URLs listed in `sources`
- Copies local XMLTV files listed in `sources`
- Extracts `.gz` guide files
- Sorts each guide with `tv_sort`
- Merges guides with `tv_merge`
- Optionally generates dummy guide entries from `dummy_channels`
- Optionally removes literal text patterns from titles/descriptions
- Optionally removes programmes after a cutoff date
- Adds missing `<channel>` entries for referenced programme channels
- Writes a final `merged.xmltv` and backs up the previous output
- Uses a per-run temporary workspace so source files in the repo are not overwritten

## Requirements

The script requires:

- `bash`
- `wget`
- `xmltv` (`tv_sort` and `tv_merge`)
- `gzip` / `gunzip`
- `sed`
- `awk`
- `mktemp`
- `perl`
- Perl module `XML::LibXML`

Install on Debian/Ubuntu:

```bash
sudo apt update
sudo apt install wget xmltv gzip sed gawk perl libxml-libxml-perl
```

Install on Alpine:

```bash
apk add wget xmltv gzip sed gawk perl perl-xml-libxml
```

## Quick Start

1. Add one source per line to `sources`.

```text
https://example.com/guide.xml
https://example.com/guide.xml.gz
/absolute/path/to/local-guide.xml
```

1. Run the merger.

```bash
./epgmerger.sh
```

1. Use the generated output.

```text
merged.xmltv
```

## Usage

```bash
./epgmerger.sh [OPTION]
```

Common examples:

```bash
# Merge all configured sources
./epgmerger.sh

# Include dummy channels
./epgmerger.sh -dummy

# Apply title/description text filtering
./epgmerger.sh -filter

# Keep programmes up to and including a fixed date
./epgmerger.sh -cutoff-date 20251231

# Keep programmes up to N days from today
./epgmerger.sh -cutoff-days 7

# Combine options
./epgmerger.sh -dummy -filter -cutoff-days 7
```

## Options

| Option | Description |
| --- | --- |
| `--help` | Show built-in help and exit. |
| `-dummy` | Generate dummy EPG entries from `dummy_channels`. |
| `-filter` | Remove literal patterns from `<title>` and `<desc>` text using `filter_epg_patterns`. |
| `-cutoff-date YYYYMMDD` | Remove programmes starting after this date. Cannot be combined with `-cutoff-days`. |
| `-cutoff-days N` | Remove programmes starting after N days from today. `N` must be a positive integer. Cannot be combined with `-cutoff-date`. |

If `-cutoff-date` is in the past, the script logs a warning because most or all programmes may be removed.

## Configuration Files

All configuration files live next to `epgmerger.sh`. Blank lines and comments are ignored. Leading/trailing whitespace and CRLF line endings are handled.

### `sources`

One source per line. Sources can be HTTP(S) URLs or local file paths.

```text
# Remote XMLTV
https://example.com/guide-a.xml
https://example.com/guide-b.xml.gz

# Local XMLTV
/srv/epg/local-guide.xml
```

Remote downloads are retried according to the `WGET_*` environment variables. Failed sources are skipped with a warning so other sources can still be processed.

### `dummy_channels`

Used only with `-dummy`.

Format:

```text
channel-id|channel-name|program-title|program-description
```

Example:

```text
DemoChannel|Demo Channel|No guide data|Placeholder programme
```

Dummy channel fields are XML-escaped before output.

### `filter_epg_patterns`

Used only with `-filter`.

Each non-empty, non-comment line is removed literally from `<title>` and `<desc>` lines in the merged output.

```text
(lang=)
dummy
```

Patterns are treated as literal text, not regular expressions.

## Environment Variables

| Variable | Default | Description |
| --- | --- | --- |
| `GENERATOR_NAME` | `epgxml-merge-dummy` | Value written to `generator-info-name` on the root `<tv>` element. |
| `GENERATOR_URL` | `https://github.com/mme89/epgxml-merge-dummy` | Value written to `generator-info-url` on the root `<tv>` element. |
| `DEFAULT_LANG` | `de` | Language code used for generated or repaired XMLTV elements. |
| `LOGFILE` | `<script_dir>/log/epgmerger.log` | Log file path. Logs also print to stdout. |
| `LOG_ROTATE_COUNT` | `4` | Number of rotated backups to keep. Set to `0` to disable rotated backups. |
| `DEBUG` | `false` | Enable debug logs with `true`, `1`, `yes`, or `on`. |
| `WGET_TRIES` | `3` | Download attempts per remote source. Must be at least `1`. |
| `WGET_WAIT` | `5` | Seconds between retry attempts. Must be `0` or greater. |
| `WGET_CONNECT_TIMEOUT` | `10` | Download connection timeout in seconds. Must be at least `1`. |
| `WGET_READ_TIMEOUT` | `20` | Download read timeout in seconds. Must be at least `1`. |
| `WGET_DNS_TIMEOUT` | `10` | Download DNS timeout in seconds. Must be at least `1`. |

Example:

```bash
GENERATOR_NAME="My EPG" DEFAULT_LANG="en" WGET_TRIES=5 ./epgmerger.sh
```

## Outputs

| File | Description |
| --- | --- |
| `merged.xmltv` | Final merged XMLTV output. |
| `merged_backup.xmltv` | Previous `merged.xmltv`, moved aside when a new output is successfully published. |
| `log/epgmerger.log` | Current log file, unless `LOGFILE` overrides it. |
| `log/epgmerger.log.N` | Rotated log backups, controlled by `LOG_ROTATE_COUNT`. |

Temporary files are created in a per-run directory under `${TMPDIR:-/tmp}` and removed at the end of a successful or failed run.

## Processing Order

1. Validate configuration and rotate logs.
2. Load source definitions from `sources`.
3. Create a temporary workspace.
4. Generate dummy XML if `-dummy` is enabled.
5. Download or copy configured sources.
6. Extract `.gz` files.
7. Normalize language attributes in staged XML files.
8. Sort each XML file with `tv_sort`.
9. Merge XML files with `tv_merge`.
10. Add missing channel definitions using XML-aware parsing.
11. Set root `<tv>` generator metadata.
12. Apply optional text filtering.
13. Apply optional cutoff date filtering.
14. Publish `merged.xmltv` and clean up temporary files.

## Notes

- XML-aware post-processing uses `XML::LibXML`, so single-quoted attributes, multiline tags, and escaped XML values are handled correctly.
- If a compressed source cannot be extracted, that source is dropped and the run continues.
- If a source cannot be sorted or merged, the script logs a warning and continues with the remaining usable sources.
- The final `merged.xmltv` is only published after processing succeeds, so a failed run should not replace the previous output.

## Troubleshooting

Check dependencies:

```bash
command -v tv_sort tv_merge wget gunzip perl
perl -MXML::LibXML -e 1
```

Run with debug logging:

```bash
DEBUG=true ./epgmerger.sh
```

Show built-in help:

```bash
./epgmerger.sh --help
```

## Note

This project was created with the assistance of AI.

## Contributing

Contributions are welcome! Feel free to open issues or submit pull requests.

## Credits

This project combines ideas from:

- [yurividal/mergexmlepg](https://github.com/yurividal/mergexmlepg)
- [yurividal/dummyepgxml](https://github.com/yurividal/dummyepgxml)
