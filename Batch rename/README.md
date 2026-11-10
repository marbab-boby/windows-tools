# Batch Rename

Renames many files or folders at once.

## How to use
1. Copy `Batch Rename.bat` into the folder with the files.
2. Double-click it.
3. Choose what to rename: all files, images, videos, PowerPoint, PDF, Word/Excel, or folders.
4. Choose whether to include subfolders.
5. Choose how to rename:
   - **New name + number**: `Flood_001`, `Flood_002` ... (by name or by date modified)
   - **Add text at the start or end**
   - **Replace text**, for example remove `Copy of `
   - **Add date at the start**: `2026-08-20_photo` (date modified)
   - **Clean up names**: spaces become `_` and odd characters are removed
6. Check the preview, then type `Y` to rename.

## Undo
Run it again and choose **8 = UNDO**. This puts the names back from the last rename.
The undo uses `_rename_log.csv`, which the tool saves in the folder, so don't delete
that file until you are happy with the new names.

## Good to know
- If a new name is already taken, it adds ` (2)`, ` (3)` and so on.
- Close any files that are open, or they can't be renamed.
