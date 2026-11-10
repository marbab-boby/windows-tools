# Windows Tools

Small double-click tools for everyday office work on Windows: renaming files, shrinking
attachments, turning photos into videos, making voice-overs and more.

Each tool is a single `.bat` file. There is nothing to install and no command line:
copy the `.bat` into a folder and double-click it.

| Tool | What it does |
|---|---|
| [Batch rename](Batch%20rename/) | Rename many files or folders at once, with preview and undo |
| [Export slides as images](Export%20slides%20as%20images/) | Save every PowerPoint slide as a PNG or JPG |
| [Extract PPT media](Extract%20the%20media%20files%20from%20the%20ppt/) | Pull the original images and videos out of PowerPoint files |
| [Folder report](Folder%20report/) | Excel report of every file and folder: sizes, types, dates |
| [Photos to video](Photos%20to%20video/) | Make an MP4 slideshow from photos, with fades, captions and music |
| [Remove duplicates](Remove%20duplicate%20images/) | Find exact copies of files and move the extras aside |
| [Script to voice over](Script%20to%20voice%20over/) | Turn a written script into a voice-over (MP3/WAV) with subtitles |
| [Shrink file size](Shrink%20file%20size/) | Make smaller copies of PowerPoints, PDFs, videos and images |

Open a tool's folder for its own instructions.

## Download
Click **Code → Download ZIP**, then unzip it. Or download just the `.bat` you need from its folder.

The first time you run a tool, Windows may show **"Windows protected your PC"**.
This happens with any downloaded script. Click **More info → Run anyway**.

## Requirements
- Windows 10 or 11
- Some tools use extra free software and offer to install it when needed:
  **FFmpeg** (videos), **Ghostscript** (PDFs), **Python** (voice-over)
- *Export slides as images* needs Microsoft PowerPoint. *Folder report* works best with Microsoft Excel.

## Safe by design
- Tools show what they will do and ask before changing anything.
- Shrink file size and Remove duplicates never change or delete your originals.
- Batch rename can undo its last rename.
