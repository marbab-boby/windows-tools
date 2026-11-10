# Folder Report

Makes an Excel report of everything in a folder and all its subfolders.

## How to use
1. Copy `Folder Report.bat` into the folder you want to check.
2. Double-click it. Nothing to choose, it just scans.
3. At the end, type `Y` to open the report.

## Result
A file named `Folder Report - <date time>.xlsx` with four sheets:
- **Summary**: total files, folders and size, broken down by type (images, videos, PDF ...) and by top-level folder
- **All files**: every file with type, size, dates, folder and an **Open** link
- **Largest files**: the 100 biggest files
- **Folders**: every folder with its total size

The window also shows a quick summary of sizes by type and the biggest folders.

## Needs
- **Microsoft Excel** for the `.xlsx` report.
  Without Excel it saves two CSV files instead (`- Files.csv` and `- Folders.csv`).
- Nothing in the folder is changed.
