# Pocket Cam

Pocket Cam records 4K 30 fps clips on a Mac from a **DJI Osmo Pocket 4P** plugged in over USB as a webcam. The first and last frame of each clip are chosen by timestamp, so a clip can start at a named moment, start a few seconds in the past, run for an exact number of frames, or wrap a script that drives the device being filmed.

We use it to film handheld devices on a desk for Pocket Nexus videos. It is a small macOS tool: one Swift recorder and one Bun command.

Pocket Cam is not affiliated with or endorsed by DJI. "DJI" and "Osmo Pocket" are trademarks of SZ DJI Technology Co., Ltd.

## Requirements

- macOS 14 or later. Tested on macOS 26 with an M3 Max.
- Xcode command line tools (`xcrun swiftc`) and [Bun](https://bun.sh).
- An Osmo Pocket 4P connected over USB-C, in webcam mode.

## Quick start

```sh
bun pocketcam.ts serve        # build build/PocketCam.app and start it
bun pocketcam.ts clip intro 8 # record 8 seconds from now: 240 frames
```

On the first start macOS asks for camera and microphone access for Pocket Cam. Clips go to `~/Downloads/pocketcam/<name>.mov`, each with a `<name>.json` beside it.

## Control page

`bun pocketcam.ts ui` opens `http://127.0.0.1:7790/`, a page served by the recorder for starting and stopping clips by hand:

- A live picture from the camera, about 4 pictures a second at 960 pixels wide, with a recording badge, the clip's running time and its frame count.
- The clip name. An empty name gives the date and time; a name already taken gets `-2`, `-3` and so on, so repeated takes can share one name.
- **Start earlier by** 0 to 3 s: the clip begins that long before the click, from the frames already in memory, to cover the time it takes to react. **Stop later by** 0 to 2 s: the clip ends that long after the stop click.
- One button, or <kbd>Space</kbd>, starts and stops. <kbd>M</kbd> or the Mark button records a labelled moment in the clip's JSON.
- The clips in the output folder, newest first, with length, frame count, size, lost frames and marks, and a button that shows the file in Finder.
- The frame rate, frames lost since the recorder started, and the free disk space with the minutes of recording it holds at the current bitrate.

The page keeps its settings in the browser's local storage.

## Commands

```sh
bun pocketcam.ts serve [--codec prores422lt] [--ring 15] [--dir <folder>] [--latency-ms 0] [--fourcc 2vuy] [--no-audio]
bun pocketcam.ts clip <name> <seconds> [--back s]     # fixed length, waits for the file
bun pocketcam.ts start [name] [--back 2]              # start 2 s in the past
bun pocketcam.ts start [name] --at 2026-11-05T10:00:00+08:00 --duration 5
bun pocketcam.ts mark "store opens"                   # a labelled time inside the clip
bun pocketcam.ts stop [--after 1]                     # stop now, or 1 s from now
bun pocketcam.ts rec <name> --pre 0.5 --post 1 -- bun drive-device.ts
bun pocketcam.ts ui | status | log | latency <ms> | quit
```

`rec` starts a clip, runs the command, and stops the clip when the command exits.

`serve` options:

| Option | Default | Meaning |
| --- | --- | --- |
| `--codec` | `prores422lt` | `prores422proxy`, `prores422lt`, `prores422`, `prores422hq`, or `hevc` (all-intra, `--bitrate-mbps 200`) |
| `--ring` | `15` | seconds of encoded frames kept in memory; the limit for `--back` |
| `--dir` | `~/Downloads/pocketcam` | where clips are written |
| `--latency-ms` | `0` | added to every in-point and out-point (see below) |
| `--fourcc` | `2vuy` | `2vuy` (4:2:2) or `420v` (4:2:0), the two formats macOS offers |
| `--no-audio` | | leave out the camera microphone |

## HTTP control

The recorder listens on `http://127.0.0.1:7790` (`POCKETCAM_PORT` changes it). Requests that change its state are POSTs, for example `curl -X POST '127.0.0.1:7790/start?name=intro&back=1'`:

| Method | Path | Parameters |
| --- | --- | --- |
| POST | `/start` | `name`, `back` (s), `after` (s), `at` (epoch s), `duration` (s), `wait=1` (answer when the file is written) |
| POST | `/stop` | `back`, `after`, `at`; answers when the file is written |
| POST | `/mark` | `label`, `back`, `at` |
| POST | `/reveal` | `name`: show the clip in Finder |
| POST | `/latency` | `ms` |
| POST | `/quit` | |
| GET | `/status` | |
| GET | `/clips` | the clips in the output folder, newest first |
| GET | `/preview.jpg` | `w` (160 to 1920): a JPEG of the next frame |
| GET | `/` | the control page |

Requests are accepted only with `Host` `127.0.0.1:7790` or `localhost:7790`, and with no `Origin` or one of those two. A page on another site can make a browser send requests to this port, and a rebound DNS name can make them look same-origin; these checks and the POST rule keep such pages from starting recordings.

The answer to `/stop` is the clip's JSON:

```json
{
  "file": "/Users/you/Downloads/pocketcam/intro.mov",
  "frames": 240,
  "duration_s": 8,
  "first_frame": "2026-11-05T04:42:34.977+08:00",
  "requested_in": "2026-11-05T04:42:34.985+08:00",
  "codec": "prores422lt",
  "source": "OsmoPocket4P UVC 2vuy 3840x2160 @ 30.0",
  "audio": "camera microphone, 24-bit PCM",
  "status": "ok"
}
```

`missing_frames` appears when frames were lost inside the clip, and `marks` when the clip has marks.

## How a clip is cut

The camera and the encoder run from `serve` until `quit`. The recorder encodes every frame as an intra-only frame and keeps the last `--ring` seconds in memory. A start or stop picks frames on that timeline:

- The first frame is the one whose timestamp is nearest the in-point, at most half a frame (16.7 ms) away. The out-point is exclusive and is rounded the same way. A clip with a duration has exactly duration × 30 frames.
- The camera takes 0.2 to 3 s to deliver its first frame after it is opened, and a new encoder loses 7 to 10 frames while it starts. Neither affects a clip, because neither is restarted for one.
- An in-point may lie in the past, as far back as the ring holds, and an in-point or out-point may lie in the future.

A timestamp is the time a frame reached the Mac on the host clock. In `2vuy` the median delay from timestamp to delivery is 0.2 ms. The delay from the moment something happens in front of the lens to the frame's timestamp is not measured yet. Once it is, `--latency-ms` moves every in-point and out-point later by that amount.

## The Osmo Pocket 4P in webcam mode

Measured on 2026-11-05:

- In webcam mode the camera is a USB 2.0 device (`bcdUSB` 0x0201, 480 Mb/s), whatever the cable. Its UVC descriptors offer MJPEG and H.265 at 3840×2160, 1920×1080 and the two portrait sizes, each at 30, 25 and 24 fps, 112 to 224 Mb/s at 4K. macOS delivers decoded frames only, as `2vuy` or `420v`; the compressed stream is not reachable through AVFoundation.
- The recorder holds the device's configuration lock across `startRunning`. Without the lock the session resets the camera to its first format, 1080×1920 at 25 fps, with the landscape picture letterboxed inside the portrait frame.
- `2vuy` is the default. Its frames arrive 33.33 ms apart with a 0.2 ms delivery delay, and their gradient across 8-pixel boundaries is 1.20 times the gradient inside the blocks; for `420v` that ratio is 1.55 and frames arrive 28 ms after their timestamp.
- Webcam mode runs at 30.000 fps. The camera's own recordings are 29.97 fps, so on a 29.97 timeline an editor drops one frame of a Pocket Cam clip about every 33 seconds.
- The webcam picture is 8-bit. Clips are ProRes 422 LT, 3840×2160, 10-bit 4:2:2, tagged BT.709 like the camera's own files, about 48 MB/s (2.9 GB per minute). Audio is the camera microphone, 48 kHz stereo, written as 24-bit PCM.
- Over about 3.5 minutes of recording with audio, no frames were lost. In one 15-second run without audio, 11 single frames were lost; the cause was not found.

## Camera permission

macOS grants camera access to the app responsible for a process, usually the terminal or editor that launched it. An app signed with the hardened runtime and without the `com.apple.security.device.camera` entitlement is refused without a prompt, and a recorder started from it gets no frames. Pocket Cam therefore runs as its own app, `build/PocketCam.app`, which declares its camera and microphone use, and macOS asks for Pocket Cam itself. The app is signed ad hoc by default, and an ad-hoc signature changes with every build, so macOS asks again after each rebuild. To keep the permission across builds, sign with a certificate: `POCKETCAM_SIGN_IDENTITY="<name from security find-identity -v -p codesigning>" bun pocketcam.ts serve`.

## Not measured yet

- The delay from light to frame timestamp (`--latency-ms`).
- The offset between the camera microphone and the picture over USB. In the camera's own recordings the sound trails the picture by about 0.1 s.

## License

MIT
