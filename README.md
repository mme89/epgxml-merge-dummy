# epgxml-merge-dummy

The epgmerger.sh script is designed to process, merge, and manage Electronic Program Guide (EPG) XML files.
It automates tasks such as downloading EPG files, generating dummy EPG entries, sorting, merging, and cleaning up temporary files.

**Requirements**
```
sudo apt install wget xmltv gzip sed 
```

## Features

- EPG File Management:
  - Download EPG files from URLs or process local files specified in sources.txt
  - Extract and process compressed .gz EPG files
  - Automatically sort and merge multiple EPG files
- Dummy EPG Creation:
  - Generate a dummy EPG using channel definitions from dummy_channels.txt (optional with -dummy flag)

## Running the Script

```
./epg_merge.sh [OPTION]
```

Options

-dummy: Generate dummy EPG using dummy_channels.txt  
--help: Show help information

## File Structure

- sources.txt: List of EPG file sources (URLs or local file paths)
- dummy_channels.txt: Definitions for dummy EPG channels and programs
- merged.xmltv: The final merged EPG file
- merged_backup.xmltv: Backup of the most recent merged EPG

## 

This script combines two repos from yurividal

- [mergexmlepg](https://github.com/yurividal/mergexmlepg)
- [dummyepgxml](https://github.com/yurividal/dummyepgxml)