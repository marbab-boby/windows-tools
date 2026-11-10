# Photos to Video

Turns a folder of photos into an MP4 slideshow.

## How to use
1. Copy `Photos to Video.bat` into the folder with the photos (at least 2).
2. To add music, put an MP3, M4A or WAV file in the same folder.
3. Double-click it and choose:
   - **Order**: by file name, or by date taken
   - **Time per photo**: 2, 3 or 5 seconds, or your own
   - **Transition**: smooth fade or straight cut
   - **Shape**: landscape 1920x1080 or 1280x720, vertical 1080x1920 (WhatsApp status / Reels), or square
   - **Background**: blurred copy of the photo, or black
   - **Captions**: show each file name on the photo
   - **Music**: pick a song or none

## Result
`<folder name> - Slideshow.mp4` in the same folder. The photos are never changed.

## Needs
- **FFmpeg**. If it is missing, the tool offers to install it (free, needs internet).
- Photos are fitted to the frame and never cropped.
