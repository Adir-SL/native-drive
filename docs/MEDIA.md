# Photos, video, and audio

Opening a picture with Return, double-click, or Space shows it in Native Drive. A cached thumbnail appears immediately, then a screen-sized preview replaces it. The original file downloads when you zoom in. Scroll or pinch to zoom, drag to pan, and use the arrow keys to move to the previous or next image in the folder. Escape closes the viewer.

HEIC and HEIF are decoded with ImageIO, including EXIF orientation and the photo's color space. JPEG, PNG, GIF, WebP, TIFF, BMP, SVG, and RAW files are shown when the system can decode them. If a file cannot be decoded, the Drive preview stays on screen with a short message.

MP4, MOV, M4V, and other formats AVFoundation can play are downloaded to a temporary file, with a progress indicator, and then played from that file. Playback starts when the item is ready. Space plays and pauses, Left and Right seek, and F toggles full screen. If playback fails, the viewer shows the underlying error with Retry and Open in default app. MP3, M4A, WAV, and similar audio files use the same player.

MKV, AVI, and other types the system player cannot open show an explanation and **Open in default app**.
