# Shrink File Size

Makes smaller copies of PowerPoint files, PDFs, videos and images, for email and WhatsApp.

## How to use
1. Copy `Shrink File Size.bat` into the folder with the files.
2. Double-click it.
3. Choose what to shrink: PowerPoint, PDF, videos, images, or everything.
4. Choose how much to shrink images, PDFs and slides: **Light**, **Medium** (recommended) or **Strong**.
5. For PowerPoints, choose whether to also shrink the videos inside them (slower).
6. For videos, choose the quality: **High** (same resolution), **Medium** (up to 1080p) or **Small** (up to 720p).

## Result
The smaller copies are saved in a `_Shrunk` subfolder with the same names.
**The original files are never changed.**
Files that can't be made noticeably smaller are skipped ("already compact").

## Needs
- **FFmpeg** for videos and **Ghostscript** for PDFs.
  If one is missing, the tool offers to install it (free, needs internet).
- PowerPoint and images need nothing extra.

## Good to know
- Only looks at files directly in the folder, not in subfolders.
- PNG images without transparency may be saved as JPG, which is much smaller.
- Videos are always saved as `.mp4`.
