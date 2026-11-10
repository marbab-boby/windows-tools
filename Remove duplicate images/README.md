# Remove Duplicates

Finds files that are exact copies of each other, even if their names are different.

## How to use
1. Copy `Remove Duplicates.bat` into the folder you want to clean.
2. Double-click it.
3. Choose what to check: images, videos, both, or all files.
4. Choose whether to include subfolders.
5. Check the list (**KEEP** is the file that stays, **copy** are the extras), then choose:
   - **Move the extra copies** to a `_Duplicates` folder (recommended)
   - **Only make a report** (`duplicates_report.csv`), change nothing
   - **Cancel**

## Good to know
- Nothing is deleted. Look through `_Duplicates`, then delete that folder yourself to free the space.
- Files are compared by content, so only true copies are found. Similar photos are not.
- The file kept is usually the original: the one with the shortest path and name, then the oldest.
