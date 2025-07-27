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
  -v, --verbose             Enable verbose output for debugging
      --skip-details        Skip downloading individual test result details (faster)
      --test-login          Test login only (no downloads)
  -h, --help               Show help message
```

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

All files are downloaded to the `nhs_downloads/` directory in the project folder:

```
nhs-records/
└── nhs_downloads/
    ├── documents/           # PDF files and embedded images
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
- Handle passkey prompts (dismisses them to use password login)
- Prompt you to enter MFA code if required
- Verify your NHS number appears on the page
- Download records to `nhs_downloads/`

#### Documents
- **Format**: PDF files
- **Location**: `nhs_downloads/documents/`
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
- **Login fails**: Check your credentials and try `./nhs_records_downloader.rb --test-login` to debug

## Features

- Automatic passkey prompt dismissal
- MFA code support with manual entry
- OTP rate limiting protection (automatic 15-minute wait)
- Duplicate detection - won't re-download files you already have
- Download history tracking
- Selective downloading by section (documents, consultations, test results)
- All files stored locally in a single `nhs_downloads` folder
- Structured data export (JSON and CSV) for consultations and test results
- Comprehensive error handling and recovery
- Summary reports for skipped/failed documents

## Requirements

- Ruby 2.7+
- Chrome browser
- ChromeDriver (automatically installed via webdrivers gem)