# Voice Over Studio (Script to Voice Over)

Turns a written script into a professional voice-over using Microsoft's neural voices.

## How to use
1. Double-click `Script to Voice Over.bat`. A window opens.
2. Type or paste the script, or open a `.txt`, `.docx` or `.md` file (`script.txt` is an example).
3. Pick a voice. The default is **Ryan** (British English). There are 300+ voices in 140+ languages.
4. Adjust speed, tone, pauses and loudness if needed.
5. Click **Preview** to hear the first lines (or only the text you selected), then **Create**.

## Result
Saved next to the `.bat` by default:
- **MP3** (on by default) and/or **WAV**, levelled to broadcast loudness
- **SRT** subtitles that match the audio

## Writing the script
- Leave a blank line between paragraphs for a longer pause.
- `[pause]` adds 1 second of silence, `[pause 2.5]` adds 2.5 seconds.
- Anything else in `[square brackets]` is a note and is not read aloud, for example `[MUSIC IN]`.
- `NARRATOR:` or `VO:` at the start of a line is not read aloud.

## Shortcuts
- **F5**: preview
- **Ctrl+Enter**: create
- **Space** (outside the text box): play / pause

## Needs
- An **internet connection** (the voice is made by Microsoft's service).
- **Python**, **FFmpeg** and **edge-tts**. If any are missing, the window offers to install them.
- Settings are remembered in `%APPDATA%\Voice Over Studio`.
