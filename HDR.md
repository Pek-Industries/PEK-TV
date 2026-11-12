# HDR, Dolby Vision and subtitles on the video path

Code: `android/app/src/main/java/com/pektv/app/MpvController.kt` (engine), `flutter_ui/lib/src/player.dart` (`SubtitleOverlay`),
`flutter_ui/lib/src/mpv.dart` (`subtitleText`, `PekOutput.setSubOverlay`), Settings > Video output.

## Which path a video takes

| Video | Screen | Path |
|---|---|---|
| SDR | any | normal renderer (`gpu`), or smooth mode (`mediacodec_embed`) if switched on |
| HDR10 / HLG, also Dolby Vision profile 7, 8 (they have an HDR10 / HLG base layer) | reports that HDR type | **direct**: MediaCodec to the screen, window colour mode HDR |
| HDR10 / HLG, DV 7 / 8 | SDR screen, or HDR output off | normal renderer, `bt.2390` tone-map to SDR |
| Dolby Vision profile 5 (no HDR10 base layer) | any | **DV renderer**: `vo=gpu-next,gpu` + `hwdec=no` (software decode), libplacebo applies the RPU and tone-maps |

Profile 5 is found through `track-list/N/dolby-vision-profile` or a `dolbyvision` colour matrix. It is detected when the file opens;
the file is then reopened once with the DV renderer at the same position (the engine cannot switch outputs on a live surface).
Smooth mode and the automatic "switch to smooth mode after dropped frames" are never used for these files (they would show purple / green).
The DV renderer decodes in software: fine for 1080p, may drop frames at 4K on a weak chip.
Dolby Vision itself is not output (mpv cannot use Android's DV decoder): profile 7 / 8 show their HDR10 / HLG layer.

## Subtitles

mpv cannot draw anything on the direct paths. A **text** subtitle (SubRip, ASS/SSA, WebVTT, mov_text, downloaded subtitles) is read from
mpv's `sub-text` property (observed, and also polled every 300 ms while it is showing) and sent to the player screen as the
`subtitle` event; `SubtitleOverlay` draws it. The video stays on the direct path, so HDR is kept. Picture subtitles (PGS, DVD, DVB)
cannot be drawn this way and still switch to the normal renderer, as before. ASS positioning and styling are not kept (plain text).
Settings > Video output > "Keep HDR with subtitles" turns the overlay off (old behaviour).

## Things to test on a device (not run here)

1. HDR10 file with an SRT subtitle on an HDR screen: HDR stays on, text shows, timing right after a seek and after Subtitle delay.
2. Same file with a PGS subtitle: switches to the normal renderer; switching back to a text subtitle returns to direct HDR.
3. Dolby Vision profile 5 file: colours correct (not purple / green), one reload at the start, log line `dolby vision: profile=5`.
4. Dolby Vision profile 8.1 file on an HDR10 screen: direct HDR10, no reload.
5. Resume from a saved position on a profile 5 file keeps the position across the reopen.
6. `adb logcat -s PEK` shows `dolby vision:`, `hdr:` and `playback:` lines.
