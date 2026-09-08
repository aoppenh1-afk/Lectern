# Audio fixture

`tone.mp3` is a generated one-second 440 Hz tone, stereo MP3 at 48 kbit/s.
It contains no ID3 or Xing header, so tests can repeat its audio frames to build
an input above the 16 MiB splitting threshold without storing a large fixture.
The low bitrate also tests that AAC export size is accounted for when splitting.

Generated with:

```sh
ffmpeg -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=1' -ac 2 -c:a libmp3lame -b:a 48k -write_xing 0 -id3v2_version 0 tone.mp3
```
