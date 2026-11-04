#!/usr/bin/env bun
// Pocket Cam: control for pocketcamd, the DJI Osmo Pocket webcam recorder.
const USAGE = `usage:
  bun pocketcam.ts serve [--codec prores422lt] [--ring 15] [--dir ~/Downloads/pocketcam] [--latency-ms 0]
  bun pocketcam.ts start [name] [--back 2] [--at <ISO time | epoch s>] [--duration s]
  bun pocketcam.ts stop [--after 1] [--back s] [--at <time>]
  bun pocketcam.ts clip <name> <seconds> [--back 0]
  bun pocketcam.ts rec <name> [--pre 0.5] [--post 1] -- <command> [args...]
  bun pocketcam.ts mark <label>
  bun pocketcam.ts status | log [lines] | latency <ms> | quit | build`;
import { $ } from "bun";
import { existsSync, statSync } from "node:fs";

const DIR = import.meta.dir;
const SRC = `${DIR}/pocketcamd.swift`;
// The recorder runs as its own small app so that macOS asks for the camera
// and microphone on its behalf. A process otherwise inherits the camera
// permission of the app that launched it (a terminal, an editor, an agent),
// and an app signed without the camera entitlement is refused without a prompt.
const APP = `${DIR}/build/PocketCam.app`;
const BIN = `${APP}/Contents/MacOS/pocketcamd`;
const LOG = `${DIR}/build/pocketcamd.log`;
const INFO_PLIST = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>nexus.pocket.cam</string>
  <key>CFBundleName</key><string>Pocket Cam</string>
  <key>CFBundleExecutable</key><string>pocketcamd</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSCameraUsageDescription</key><string>Pocket Cam records clips from a DJI Osmo Pocket connected as a webcam.</string>
  <key>NSMicrophoneUsageDescription</key><string>Pocket Cam records the camera's microphone with each clip.</string>
</dict></plist>
`;
const PORT = process.env.POCKETCAM_PORT ?? "7790";
const BASE = `http://127.0.0.1:${PORT}`;

type Flags = { _: string[]; cmd: string[]; [k: string]: any };
function parse(args: string[]): Flags {
  const f: Flags = { _: [], cmd: [] };
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--") { f.cmd = args.slice(i + 1); break; }
    if (a.startsWith("--")) {
      const k = a.slice(2);
      const v = args[i + 1];
      if (v === undefined || v.startsWith("--")) f[k] = true;
      else { f[k] = v; i++; }
    } else f._.push(a);
  }
  return f;
}

function epoch(s: string): number {
  if (/^\d+(\.\d+)?$/.test(s)) return Number(s);
  const t = Date.parse(s);
  if (Number.isNaN(t)) throw new Error(`not a time: ${s}`);
  return t / 1000;
}

async function api(path: string, q: Record<string, unknown> = {}) {
  const u = new URL(path, BASE);
  for (const [k, v] of Object.entries(q)) if (v !== undefined && v !== false) u.searchParams.set(k, String(v));
  let r: Response;
  try {
    r = await fetch(u);
  } catch {
    console.error(`pocketcamd is not running on ${BASE}. Start it with: bun ${DIR}/pocketcam.ts serve`);
    process.exit(1);
  }
  const j: any = await r.json();
  if (!r.ok) {
    console.error(JSON.stringify(j, null, 2));
    process.exit(1);
  }
  return j;
}

async function alive() {
  try { return (await fetch(`${BASE}/status`)).ok; } catch { return false; }
}

// Rebuilding changes the ad-hoc signature, and macOS asks for the camera again.
async function build() {
  if (existsSync(BIN) && statSync(BIN).mtimeMs >= statSync(SRC).mtimeMs) return;
  await $`mkdir -p ${APP}/Contents/MacOS`;
  await Bun.write(`${APP}/Contents/Info.plist`, INFO_PLIST);
  await $`xcrun swiftc -O -swift-version 5 -o ${BIN} ${SRC}`.quiet();
  await $`codesign --force --sign - ${APP}`.quiet();
}

function printClip(j: any) {
  const miss = j.missing_frames ? `, MISSING ${JSON.stringify(j.missing_frames)}` : "";
  console.log(`${j.file}\n  ${j.frames} frames, ${j.duration_s} s, first frame ${j.first_frame}${miss}`);
}

const [cmd, ...rest] = process.argv.slice(2);
const f = parse(rest);

switch (cmd) {
  case "build":
    await build();
    console.log(BIN);
    break;

  case "serve": {
    if (await alive()) { console.log("pocketcamd is already running"); console.log(await api("/status")); break; }
    await build();
    await $`open -n ${APP} --args --port ${PORT} --log ${LOG} ${rest}`;
    console.error("waiting for the camera (the first start asks for camera and microphone access)…");
    const t0 = Date.now();
    while (Date.now() - t0 < 90000) {
      if (await alive()) {
        const s = await api("/status");
        if (s.fps_measured) { console.log(s); process.exit(0); }
      }
      await Bun.sleep(300);
    }
    console.error(`pocketcamd did not come up in 90 s; log:\n${(await $`tail -20 ${LOG}`.nothrow().text())}`);
    process.exit(1);
  }

  case "start": {
    const j = await api("/start", { name: f._[0], back: f.back, at: f.at && epoch(f.at), duration: f.duration });
    console.log(`recording ${j.name}: first frame ${j.first_frame}`);
    break;
  }

  case "stop": {
    const at = f.at ? epoch(f.at) : f.after ? Date.now() / 1000 + Number(f.after) : undefined;
    printClip(await api("/stop", { at, back: f.back }));
    break;
  }

  case "clip": {
    const [name, secs] = f._;
    if (!name || !secs) { console.error("usage: clip <name> <seconds> [--back s]"); process.exit(64); }
    printClip(await api("/start", { name, duration: secs, back: f.back, wait: 1 }));
    break;
  }

  case "rec": {
    const name = f._[0];
    if (!name || f.cmd.length === 0) { console.error("usage: rec <name> [--pre s] [--post s] -- <command...>"); process.exit(64); }
    await api("/start", { name, back: f.pre });
    const p = Bun.spawn(f.cmd, { stdio: ["inherit", "inherit", "inherit"] });
    const code = await p.exited;
    printClip(await api("/stop", { at: Date.now() / 1000 + Number(f.post ?? 0) }));
    process.exit(code);
  }

  case "mark":
    console.log(await api("/mark", { label: f._.join(" ") }));
    break;

  case "latency":
    console.log(await api("/latency", { ms: f._[0] }));
    break;

  case "status":
    console.log(JSON.stringify(await api("/status"), null, 2));
    break;

  case "log":
    console.log(await $`tail -n ${f._[0] ?? 40} ${LOG}`.text());
    break;

  case "quit":
    await api("/quit");
    console.log("stopped");
    break;

  default:
    console.log(USAGE);
}
