# NHS Records Downloader

A Ruby script to securely download your NHS GP records, documents, and test results locally.

## Security Note

**All credentials remain on your local machine only.** This script does not send any data to external servers.

## Prerequisites

- Ruby 2.7 or higher
- Chrome browser installed
- Bundler gem (`gem install bundler` if not installed)
- 1Password CLI (optional, but recommended): `brew install --cask 1password-cli`

## Setup

### Quick Setup

1. Clone this repository and navigate to it:
   ```bash
   cd nhs-records
   ```

2. Install Ruby dependencies:
   ```bash
   bundle install
   ```

3. Run the interactive setup script:
   ```bash
   ruby setup.rb
   ```

   This will:
   - Ask if you're using 1Password CLI
   - Configure your login method
   - Ask where downloads should be saved (default: `./nhs_downloads`)
   - Validate and format your NHS number
   - Create the `.env` file

4. Test your setup:
   ```bash
   ./nhs_records_downloader.rb --test-login
   ```

### Manual Setup

#### Option 1: Using 1Password CLI (Recommended)

1. Install 1Password CLI:
   ```bash
   brew install --cask 1password-cli
   ```

2. Sign in to 1Password:
   ```bash
   eval $(op signin)
   ```
   
   Note: The script will prompt you to run this command if your 1Password session has expired.

3. Either run the setup script:
   ```bash
   ruby setup.rb
   ```
   
   Or manually create `.env`:
   ```
   ONEPASSWORD_NHS_ITEM=NHS
   NHS_NUMBER=XXX XXX XXXX
   ```

#### Option 2: Using Environment Variables

Create `.env` with:
```
NHS_EMAIL=your_email@example.com
NHS_PASSWORD=your_password
NHS_NUMBER=your_nhs_number
```

## Usage

### Basic Usage

Run the main script to download all records:
```bash
./nhs_records_downloader.rb
```

### Command Line Options

```bash
./nhs_records_downloader.rb [options]

Options:
  -s, --sections SECTIONS    Comma-separated list of sections to download
                            (documents, consultations, test)
  -o, --output-dir PATH      Save downloads here instead of ./nhs_downloads
  -v, --verbose             Enable verbose output for debugging
      --skip-details        Skip downloading individual test result details (faster)
      --test-login          Test login only (no downloads)
  -h, --help               Show help message
```

You can also set the location in `.env` with `NHS_OUTPUT_DIR=~/Documents/Medical`
(the `--output-dir` flag takes precedence).

### Examples

Download only test results:
```bash
./nhs_records_downloader.rb -s test
```

Download only documents and consultations:
```bash
./nhs_records_downloader.rb -s documents,consultations
```

Quick scan of test results without details:
```bash
./nhs_records_downloader.rb -s test --skip-details
```

Debug mode with verbose output:
```bash
./nhs_records_downloader.rb -s test -v
```

### Download Location and Formats

By default all files are downloaded to the `nhs_downloads/` directory in the
project folder. Use `-o PATH` or `NHS_OUTPUT_DIR` to save them somewhere else,
for example an existing records folder:

```bash
./nhs_records_downloader.rb -o ~/Documents/Medical
```

Everything, including `download_history.json`, the CSV/JSON exports, the rate
limit lock and the skipped documents report, is written to that directory, so
the folder is self-contained.

When the output directory already contains documents from a previous download
(named `YYYY-MM-DD_doctype_xxxxxxxx.ext`), they are treated as already
downloaded: a document on the NHS side is skipped if a file with the same date
and document type is present. Matching is by filename, so files renamed by
hand or saved under a different scheme will not be recognised.

```
nhs-records/
└── nhs_downloads/
    ├── 2025-07-21_letter_a1b2c3d4.pdf   # Downloaded documents and images
    ├── consultations_and_events.json
    ├── consultations_and_events.csv
    ├── test_results.json
    ├── test_results.csv
    ├── download_history.json
    └── skipped_documents_report.txt
```

### What the script downloads

The script will:
- Open a Chrome browser window
- Navigate to NHS login
- Enter your credentials automatically (from 1Password or .env)
- Pause when NHS login asks for a passkey so you can complete it (Touch ID, Windows Hello, your phone or a security key), or choose to use your password instead
- Prompt you to enter MFA code if required
- Verify your NHS number appears on the page
- Download records to the output directory (`nhs_downloads/` by default)

#### Documents
- **Format**: PDF files
- **Location**: the output directory (documents sit alongside the exports)
- PDF letters and documents from your GP records
- Embedded images extracted from documents
- Creates `skipped_documents_report.txt` for any documents that couldn't be downloaded

#### Consultations and Events
- **Formats**: JSON and CSV
- **Files**: `consultations_and_events.json` and `consultations_and_events.csv`
- All consultation records with dates, locations, and staff
- Includes entry types: medications, test results, problems, notes, etc.

#### Test Results
- **Formats**: JSON and CSV
- **Files**: `test_results.json` and `test_results.csv`
- All test results across all available years
- Full test details including values, ranges, and clinical notes

## Troubleshooting

- **"cannot load such file -- selenium-webdriver"**: Run `bundle install` first
- **"1Password CLI is not signed in"**: Run `eval $(op signin)` in your terminal
- **"Could not find 1Password item"**: Ensure your NHS login item exists in 1Password
- **"Passkey required"**: Finish the passkey prompt in the Chrome window (Touch ID, Windows Hello, phone or security key) and the script continues on its own. It waits 3 minutes before giving up; choosing "use your password instead" on that page also works.
- **Login fails**: Check your credentials and try `./nhs_records_downloader.rb --test-login` to debug

## Features

- Pauses for passkey login when NHS login asks for one
- MFA code support with manual entry
- OTP rate limiting protection (automatic 15-minute wait)
- Duplicate detection - won't re-download files you already have
- Download history tracking
- Selective downloading by section (documents, consultations, test results)
- All files stored locally in a single output folder
- Structured data export (JSON and CSV) for consultations and test results
- Comprehensive error handling and recovery
- Summary reports for skipped/failed documents

## Requirements

- Ruby 2.7+
- Chrome browser
- ChromeDriver (automatically installed via webdrivers gem)