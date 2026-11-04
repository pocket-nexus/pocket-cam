// pocketcamd, the Pocket Cam recorder: holds a DJI Osmo Pocket open in UVC
// webcam mode (4K30), encodes every frame as an intra-only frame (ProRes, or
// all-intra HEVC) into a ring buffer in memory, and writes clips whose first
// and last frames are chosen by timestamp. Control is HTTP on 127.0.0.1
// (see pocketcam.ts).
//
// The camera and encoder never stop between clips, so a clip does not pay the
// camera's 0.2–3 s start-up or the encoder's warm-up, and an in-point may lie
// in the past as far as the ring reaches.
//
// It runs as build/PocketCam.app (pocketcam.ts builds and opens it) so that
// macOS asks for the camera on its own behalf. A process otherwise inherits
// the camera permission of the app that launched it, and an app signed
// without the camera entitlement is refused without a prompt.
import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import Network
import VideoToolbox

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: options

let argv = CommandLine.arguments
func opt(_ k: String, _ d: String) -> String {
  if let i = argv.firstIndex(of: k), i + 1 < argv.count { return argv[i + 1] }
  return d
}
let wantFourcc = opt("--fourcc", "2vuy")
let wantWidth = Int32(opt("--width", "3840")) ?? 3840
let fps = Double(opt("--fps", "30")) ?? 30
let codecName = opt("--codec", "prores422lt")
let hevcMbps = Double(opt("--bitrate-mbps", "200")) ?? 200
let ringSeconds = Double(opt("--ring", "15")) ?? 15
let port = UInt16(opt("--port", "7790")) ?? 7790
let outDir = URL(fileURLWithPath: (opt("--dir", "~/Downloads/pocketcam") as NSString).expandingTildeInPath)
var latency = (Double(opt("--latency-ms", "0")) ?? 0) / 1000
let deviceMatch = opt("--device", "Osmo")
let withAudio = !argv.contains("--no-audio")
let webDir = opt("--web", "")  // folder holding index.html, read on every request
let FD = 1 / fps

let codecs: [String: CMVideoCodecType] = [
  "prores422proxy": kCMVideoCodecType_AppleProRes422Proxy,
  "prores422lt": kCMVideoCodecType_AppleProRes422LT,
  "prores422": kCMVideoCodecType_AppleProRes422,
  "prores422hq": kCMVideoCodecType_AppleProRes422HQ,
  "hevc": kCMVideoCodecType_HEVC,  // all-intra (every frame a keyframe)
]
let codec: CMVideoCodecType = codecs[codecName] ?? {
  print("unknown --codec \(codecName); one of \(codecs.keys.sorted())"); exit(64)
}()

// MARK: clocks and logging

let isoFmt: DateFormatter = {
  let f = DateFormatter()
  f.locale = Locale(identifier: "en_US_POSIX")
  f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"
  return f
}()
func iso(_ wall: Double) -> String { isoFmt.string(from: Date(timeIntervalSince1970: wall)) }
func hostNow() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
func wallNow() -> Double { Date().timeIntervalSince1970 }
// Sample timestamps are on the host clock; requests may name wall-clock times.
func hostToWall(_ h: Double) -> Double { wallNow() - (hostNow() - h) }
func wallToHost(_ w: Double) -> Double { hostNow() - (wallNow() - w) }
let logFile: FileHandle? = {
  let p = opt("--log", "")
  guard !p.isEmpty else { return nil }
  if !FileManager.default.fileExists(atPath: p) { FileManager.default.createFile(atPath: p, contents: nil) }
  let h = FileHandle(forWritingAtPath: p)
  h?.seekToEndOfFile()
  return h
}()
func log(_ s: String) {
  let line = "\(iso(wallNow()).dropFirst(11).prefix(12))  \(s)"
  print(line)
  logFile?.write((line + "\n").data(using: .utf8)!)
}
func fourcc(_ v: FourCharCode) -> String {
  let b = [24, 16, 8, 0].map { UInt8((v >> UInt32($0)) & 0xff) }
  return String(bytes: b, encoding: .ascii) ?? "\(v)"
}
func r3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }

// MARK: permission, device, format

func ensureAccess(_ type: AVMediaType) -> Bool {
  switch AVCaptureDevice.authorizationStatus(for: type) {
  case .authorized: return true
  case .notDetermined:
    let sem = DispatchSemaphore(value: 0)
    var ok = false
    AVCaptureDevice.requestAccess(for: type) { g in ok = g; sem.signal() }
    sem.wait()
    return ok
  default: return false
  }
}
guard ensureAccess(.video) else {
  log("camera access refused. Start it with `bun pocketcam.ts serve` and allow Pocket Cam in")
  log("System Settings → Privacy & Security → Camera.")
  exit(2)
}
let audioAllowed = withAudio && ensureAccess(.audio)

let videoDevices = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified).devices
let dev: AVCaptureDevice = videoDevices.first(where: { $0.localizedName.contains(deviceMatch) }) ?? {
  log("no video device matching \"\(deviceMatch)\"; found \(videoDevices.map { $0.localizedName })"); exit(3)
}()
let cameraName = dev.localizedName
let audioDev = audioAllowed
  ? AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
      .devices.first(where: { $0.localizedName.contains(deviceMatch) })
  : nil

func describe(_ f: AVCaptureDevice.Format) -> String {
  let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
  return "\(fourcc(CMFormatDescriptionGetMediaSubType(f.formatDescription))) \(d.width)x\(d.height)"
}
let format: AVCaptureDevice.Format = dev.formats.first(where: { f in
  CMVideoFormatDescriptionGetDimensions(f.formatDescription).width == wantWidth
    && fourcc(CMFormatDescriptionGetMediaSubType(f.formatDescription)) == wantFourcc
    && f.videoSupportedFrameRateRanges.contains { abs($0.maxFrameRate - fps) < 0.01 }
}) ?? {
  log("no \(wantFourcc) format \(wantWidth) wide at \(fps) fps; formats: \(dev.formats.map(describe))"); exit(4)
}()
let rateRange = format.videoSupportedFrameRateRanges.first { abs($0.maxFrameRate - fps) < 0.01 }!
let frameDur = rateRange.minFrameDuration

// MARK: shared state (sq), capture counters (cq)

let sq = DispatchQueue(label: "pocketcam.state")
let cq = DispatchQueue(label: "pocketcam.capture", qos: .userInteractive)

struct VFrame { let t: Double; let pts: CMTime; let sb: CMSampleBuffer; let bytes: Int }
struct AChunk { let t: Double; let end: Double; let sb: CMSampleBuffer }

// sq
var vring: [VFrame] = []
var aring: [AChunk] = []
var ringBytes = 0
var vfmt: CMFormatDescription?
var afmt: CMFormatDescription?
var encoded = 0
var encodeErrors = 0
var clip: Clip?
var history: [[String: Any]] = []
var quitAfterClip = false
// cq
var captured = 0
var captureDrops = 0
var captureGaps = 0
var lastCaptureT = 0.0
var srcDims = CMVideoDimensions(width: 0, height: 0)
var srcSubtype = ""
var vt: VTCompressionSession?
// preview requests wait for the next captured frame; no frame is held between requests
var previewWaiters: [(NWConnection, Int)] = []
let pq = DispatchQueue(label: "pocketcam.preview")
let ciContext = CIContext()

func renderPreview(_ pb: CVPixelBuffer, _ waiters: [(NWConnection, Int)]) {
  let img = CIImage(cvPixelBuffer: pb)
  for (c, w) in waiters {
    let s = CGFloat(w) / img.extent.width
    let scaled = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
    guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
          let jpg = ciContext.jpegRepresentation(of: scaled, colorSpace: cs, options: [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.75,
          ]) else { respond(c, 500, ["error": "preview failed"]); continue }
    respondData(c, 200, "image/jpeg", jpg)
  }
}

// MARK: clip

final class Clip {
  let name: String
  let url: URL
  let cmdIn: Double      // host time the in-point was asked for, before latency
  let reqIn: Double      // host time of the in-point, after latency
  var cmdOut: Double?
  var reqOut: Double?
  var writer: AVAssetWriter?
  var wv: AVAssetWriterInput?
  var wa: AVAssetWriterInput?
  var vq: [VFrame] = []
  var aq: [CMSampleBuffer] = []
  var taken: [(t: Double, pts: CMTime)] = []  // every frame accepted, in order
  var first: VFrame?
  var gaps: [[String: Any]] = []
  var videoDone = false
  var endPTS: CMTime?
  var audioTo = 0.0
  var finishing = false
  var marks: [[String: Any]] = []
  var waiters: [NWConnection] = []
  var bytes = 0
  var failed: String?

  init(name: String, url: URL, cmdIn: Double, reqIn: Double) {
    self.name = name; self.url = url; self.cmdIn = cmdIn; self.reqIn = reqIn
  }

  // a frame belongs to the clip when its timestamp is nearest to a time in
  // [in, out): first frame with t >= in - FD/2, first excluded with t >= out - FD/2
  func feed(_ f: VFrame) {
    if videoDone || failed != nil || f.t < reqIn - FD / 2 { return }
    if let out = reqOut, f.t >= out - FD / 2 {
      videoDone = true; endPTS = f.pts; drain(); return
    }
    if writer == nil { open(f) }
    guard failed == nil else { return }
    if let l = taken.last, f.t - l.t > 1.5 * FD {
      gaps.append(["at_s": r3(l.t - first!.t), "missing_frames": Int(((f.t - l.t) / FD).rounded()) - 1])
      log("clip \(name): \(Int(((f.t - l.t) / FD).rounded()) - 1) frame(s) missing at \(String(format: "%.2f", l.t - first!.t)) s")
    }
    taken.append((f.t, f.pts)); vq.append(f); bytes += f.bytes
    drain()
  }

  func open(_ f: VFrame) {
    first = f
    do {
      try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let w = try AVAssetWriter(outputURL: url, fileType: .mov)
      let v = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: vfmt)
      v.expectsMediaDataInRealTime = true
      w.add(v); wv = v
      if let af = afmt, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(af)?.pointee {
        // LPCM passthrough next to passthrough video fails on the first audio
        // sample (-12780), so the writer re-packs the PCM itself
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = asbd.mChannelsPerFrame == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
          AVFormatIDKey: kAudioFormatLinearPCM,
          AVSampleRateKey: asbd.mSampleRate,
          AVNumberOfChannelsKey: Int(asbd.mChannelsPerFrame),
          AVLinearPCMBitDepthKey: 24,
          AVLinearPCMIsFloatKey: false,
          AVLinearPCMIsBigEndianKey: false,
          AVLinearPCMIsNonInterleaved: false,
          AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
        ], sourceFormatHint: af)
        a.expectsMediaDataInRealTime = true
        if w.canAdd(a) { w.add(a); wa = a }
      }
      guard w.startWriting() else { throw w.error ?? NSError(domain: "pocketcam", code: 1) }
      w.startSession(atSourceTime: f.pts)
      writer = w
    } catch {
      failed = "writer: \(error)"; log("clip \(name): \(failed!)"); finishFailed(); return
    }
    if wa != nil {
      for a in aring where a.end > f.t {
        if let s = trimFront(a, to: f.t) { aq.append(s); audioTo = a.end }
      }
    }
    log("clip \(name): first frame \(iso(hostToWall(f.t)))")
  }

  func audio(_ a: AChunk) {
    guard writer != nil, wa != nil, !finishing, failed == nil, a.end > first!.t else { return }
    if let e = endPTS, audioTo >= e.seconds { return }
    guard let s = trimFront(a, to: first!.t) else { return }
    aq.append(s); audioTo = a.end
    drain()
  }

  // the chunk that straddles the first frame is cut at the first frame's
  // time, so the audio track starts with the picture to the sample
  func trimFront(_ a: AChunk, to t0: Double) -> CMSampleBuffer? {
    if a.t >= t0 { return a.sb }
    guard let fd = CMSampleBufferGetFormatDescription(a.sb),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee else { return nil }
    let n = CMSampleBufferGetNumSamples(a.sb)
    let k = Int(((t0 - a.t) * asbd.mSampleRate).rounded(.up))
    if k >= n { return nil }
    var out: CMSampleBuffer?
    let st = CMSampleBufferCopySampleBufferForRange(allocator: nil, sampleBuffer: a.sb,
                                                    sampleRange: CFRange(location: k, length: n - k), sampleBufferOut: &out)
    return st == noErr ? out : nil
  }

  // out-point; frames already taken at or past it are cut by the movie's edit
  func stop(cmd: Double, out: Double) {
    cmdOut = cmd; reqOut = out
    if videoDone { return }
    if let x = taken.first(where: { $0.t >= out - FD / 2 }) {
      videoDone = true; endPTS = x.pts
      vq.removeAll { $0.t >= x.t }
    }
    drain()
  }

  func drain() {
    if failed != nil { return }
    if let v = wv {
      while v.isReadyForMoreMediaData, !vq.isEmpty {
        let f = vq.removeFirst()
        if !v.append(f.sb) { failed = "append: \(String(describing: writer?.error))"; log("clip \(name): \(failed!)"); finishFailed(); return }
      }
    }
    if let a = wa {
      while a.isReadyForMoreMediaData, !aq.isEmpty {
        let s = aq.removeFirst()
        if !a.append(s) {
          failed = "audio append at \(CMSampleBufferGetPresentationTimeStamp(s).seconds - first!.t) s: \(String(describing: writer?.error))"
          log("clip \(name): \(failed!)"); finishFailed(); return
        }
      }
    }
    maybeFinish()
  }

  func maybeFinish() {
    guard videoDone, !finishing, vq.isEmpty, aq.isEmpty, let e = endPTS else { return }
    guard let w = writer else { finishFailed(); return }
    // wait (up to 1.5 s) for the camera's audio to reach the out-point
    if wa != nil && audioTo < e.seconds && hostNow() < e.seconds + 1.5 { return }
    finishing = true
    w.endSession(atSourceTime: e)
    wv?.markAsFinished(); wa?.markAsFinished()
    w.finishWriting { sq.async { self.done() } }
  }

  func info() -> [String: Any] {
    var o: [String: Any] = ["name": name, "file": url.path, "requested_in": iso(hostToWall(cmdIn))]
    if let c = cmdOut { o["requested_out"] = iso(hostToWall(c)) }
    if let f = first {
      let end = endPTS?.seconds
      let n = taken.filter { end == nil || $0.t < end! }.count
      o["first_frame"] = iso(hostToWall(f.t))
      o["frames"] = n
      o["duration_s"] = r3((end ?? (taken.last!.t + FD)) - f.t)
      if let end { o["end"] = iso(hostToWall(end)) }
    } else {
      o["first_frame"] = "waiting for \(iso(hostToWall(reqIn)))"
    }
    if !gaps.isEmpty { o["missing_frames"] = gaps }
    if !marks.isEmpty { o["marks"] = marks }
    return o
  }

  func done() {
    var o = info()
    o["status"] = writer?.status == .completed ? "ok" : "error: \(String(describing: writer?.error))"
    o["source"] = "\(cameraName) UVC \(srcSubtype) \(srcDims.width)x\(srcDims.height) @ \(fps)"
    o["codec"] = codecName
    o["audio"] = wa != nil ? "camera microphone, 24-bit PCM" : "none"
    o["latency_ms"] = latency * 1000
    o["bytes"] = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    let json = try! JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys])
    try? json.write(to: url.deletingPathExtension().appendingPathExtension("json"))
    log("clip \(name): \(o["frames"] ?? 0) frames, \(o["duration_s"] ?? 0) s → \(url.path)")
    history.append(o)
    for c in waiters { respond(c, 200, o) }
    waiters = []
    clip = nil
    if quitAfterClip { exit(0) }
  }

  func finishFailed() {
    finishing = true
    writer?.cancelWriting()
    var o = info(); o["status"] = "error: \(failed ?? "no frames in range")"
    for c in waiters { respond(c, 500, o) }
    waiters = []
    history.append(o)
    clip = nil
    if quitAfterClip { exit(1) }
  }
}

// MARK: encoder and capture

func makeEncoder(_ w: Int32, _ h: Int32, color: CMFormatDescription) {
  var s: VTCompressionSession?
  let st = VTCompressionSessionCreate(allocator: nil, width: w, height: h, codecType: codec,
                                      encoderSpecification: nil, imageBufferAttributes: nil,
                                      compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                      compressionSessionOut: &s)
  guard st == noErr, let s else { log("VTCompressionSessionCreate failed: \(st)"); exit(5) }
  VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
  // the camera's color tags (BT.709 on the 2vuy stream) go into every clip;
  // without them the movie carries the matrix only
  let tags: [(CFString, CFString)] = [
    (kCMFormatDescriptionExtension_ColorPrimaries, kVTCompressionPropertyKey_ColorPrimaries),
    (kCMFormatDescriptionExtension_TransferFunction, kVTCompressionPropertyKey_TransferFunction),
    (kCMFormatDescriptionExtension_YCbCrMatrix, kVTCompressionPropertyKey_YCbCrMatrix),
  ]
  for (ext, key) in tags {
    if let v = CMFormatDescriptionGetExtension(color, extensionKey: ext) {
      VTSessionSetProperty(s, key: key, value: v)
      log("color \(key): \(v)")
    }
  }
  if codec == kCMVideoCodecType_HEVC {
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 1 as CFNumber)
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: Int(hevcMbps * 1e6) as CFNumber)
  }
  VTCompressionSessionPrepareToEncodeFrames(s)
  vt = s
}

func onEncoded(_ sb: CMSampleBuffer) {
  let pts = CMSampleBufferGetPresentationTimeStamp(sb)
  if vfmt == nil {
    vfmt = CMSampleBufferGetFormatDescription(sb)
    log("encoder: \(codecName) (\(fourcc(CMFormatDescriptionGetMediaSubType(vfmt!))))")
  }
  encoded += 1
  let f = VFrame(t: pts.seconds, pts: pts, sb: sb, bytes: CMSampleBufferGetTotalSampleSize(sb))
  vring.append(f); ringBytes += f.bytes
  while let o = vring.first, f.t - o.t > ringSeconds { ringBytes -= o.bytes; vring.removeFirst() }
  clip?.feed(f)
}

func onAudio(_ sb: CMSampleBuffer) {
  if afmt == nil { afmt = CMSampleBufferGetFormatDescription(sb) }
  let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
  var d = CMSampleBufferGetDuration(sb).seconds
  if !d.isFinite || d <= 0, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(afmt!)?.pointee {
    d = Double(CMSampleBufferGetNumSamples(sb)) / asbd.mSampleRate
  }
  let a = AChunk(t: t, end: t + d, sb: sb)
  aring.append(a)
  while let o = aring.first, a.t - o.t > ringSeconds { aring.removeFirst() }
  clip?.audio(a)
}

final class Capture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
  var vout: AVCaptureVideoDataOutput?
  let startCall = hostNow()

  func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
    guard o === vout else { sq.async { onAudio(sb) }; return }
    guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
    let pts = CMSampleBufferGetPresentationTimeStamp(sb)
    let t = pts.seconds
    if captured == 0 {
      let fd = CMSampleBufferGetFormatDescription(sb)!
      srcDims = CMVideoFormatDescriptionGetDimensions(fd)
      srcSubtype = fourcc(CMFormatDescriptionGetMediaSubType(fd))
      log(String(format: "first frame %.2f s after start: %@ %dx%d", hostNow() - startCall, srcSubtype, srcDims.width, srcDims.height))
      if srcDims.width != wantWidth { log("WARNING: the camera sends \(srcDims.width)x\(srcDims.height), not the requested format") }
      makeEncoder(srcDims.width, srcDims.height, color: fd)
    }
    if lastCaptureT > 0, t - lastCaptureT > 1.5 * FD {
      captureGaps += 1
      log(String(format: "capture gap %.1f ms", (t - lastCaptureT) * 1000))
    }
    lastCaptureT = t
    captured += 1
    VTCompressionSessionEncodeFrame(vt!, imageBuffer: pb, presentationTimeStamp: pts, duration: frameDur,
                                    frameProperties: nil, infoFlagsOut: nil) { status, _, out in
      guard status == noErr, let out else { sq.async { encodeErrors += 1 }; return }
      sq.async { onEncoded(out) }
    }
    if !previewWaiters.isEmpty {
      let ws = previewWaiters
      previewWaiters = []
      pq.async { renderPreview(pb, ws) }
    }
  }

  func captureOutput(_ o: AVCaptureOutput, didDrop sb: CMSampleBuffer, from c: AVCaptureConnection) {
    guard o === vout else { return }
    captureDrops += 1
    let r = CMGetAttachment(sb, key: kCMSampleBufferAttachmentKey_DroppedFrameReason, attachmentModeOut: nil)
    log("capture dropped a frame: \(String(describing: r))")
  }
}

let cap = Capture()
let session = AVCaptureSession()
session.beginConfiguration()
session.addInput(try AVCaptureDeviceInput(device: dev))
if let a = audioDev, let ain = try? AVCaptureDeviceInput(device: a), session.canAddInput(ain) { session.addInput(ain) }
// the device lock is held across startRunning: without it the session resets
// the camera to its default format (1080x1920 at 25 fps on the Pocket 4P)
try dev.lockForConfiguration()
dev.activeFormat = format
dev.activeVideoMinFrameDuration = frameDur
dev.activeVideoMaxFrameDuration = frameDur
let vout = AVCaptureVideoDataOutput()
vout.videoSettings = [:]  // the device's own pixel format, no conversion
vout.alwaysDiscardsLateVideoFrames = false
vout.setSampleBufferDelegate(cap, queue: cq)
session.addOutput(vout)
cap.vout = vout
if audioDev != nil {
  let aout = AVCaptureAudioDataOutput()
  aout.setSampleBufferDelegate(cap, queue: cq)
  if session.canAddOutput(aout) { session.addOutput(aout) }
}
session.commitConfiguration()
NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { n in
  log("SESSION ERROR: \(String(describing: n.userInfo?[AVCaptureSessionErrorKey]))")
}
NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { n in
  if (n.object as? AVCaptureDevice) == dev { log("CAMERA DISCONNECTED"); exit(6) }
}
session.startRunning()
dev.unlockForConfiguration()
log("\(dev.localizedName): \(describe(format)) @ \(fps) fps, audio: \(audioDev?.localizedName ?? "off"), codec \(codecName), ring \(ringSeconds) s")

// MARK: HTTP control

func respondData(_ c: NWConnection, _ code: Int, _ type: String, _ body: Data) {
  let head = "HTTP/1.1 \(code) \(code == 200 ? "OK" : "Error")\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
  c.send(content: head.data(using: .utf8)! + body, completion: .contentProcessed { _ in c.cancel() })
}

func respond(_ c: NWConnection, _ code: Int, _ obj: Any) {
  let body = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])) ?? Data()
  respondData(c, code, "application/json", body)
}

// a time named by the request: `at` (wall-clock epoch seconds), or the
// arrival moved by `back` (seconds earlier) and `after` (seconds later)
func requestTime(_ q: [String: String], _ arrival: Double) -> Double {
  if let a = q["at"], let w = Double(a) { return wallToHost(w) }
  return arrival - (Double(q["back"] ?? "0") ?? 0) + (Double(q["after"] ?? "0") ?? 0)
}

// clips on disk, newest first, from their JSON sidecars
func listClips() -> [[String: Any]] {
  let fm = FileManager.default
  guard let items = try? fm.contentsOfDirectory(at: outDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
  return items.filter { $0.pathExtension == "json" }
    .compactMap { u -> (Date, [String: Any])? in
      guard fm.fileExists(atPath: u.deletingPathExtension().appendingPathExtension("mov").path),
            let d = try? Data(contentsOf: u),
            let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
      return ((try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast, o)
    }
    .sorted { $0.0 > $1.0 }
    .prefix(50).map { $0.1 }
}

func clipURL(_ raw: String?) -> (String, URL) {
  let stamp: String = {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
    return f.string(from: Date())
  }()
  var name = (raw ?? "").components(separatedBy: CharacterSet(charactersIn: "/\\:\0")).joined(separator: "-")
  if name.isEmpty { name = stamp }
  var url = outDir.appendingPathComponent(name + ".mov")
  var k = 2
  while FileManager.default.fileExists(atPath: url.path) {
    url = outDir.appendingPathComponent("\(name)-\(k).mov"); k += 1
  }
  return (url.deletingPathExtension().lastPathComponent, url)
}

func status() -> [String: Any] {
  var capturedN = 0, drops = 0, gaps = 0
  var dims = CMVideoDimensions(width: 0, height: 0), sub = ""
  cq.sync { capturedN = captured; drops = captureDrops; gaps = captureGaps; dims = srcDims; sub = srcSubtype }
  var o: [String: Any] = [
    "camera": dev.localizedName, "source": "\(sub) \(dims.width)x\(dims.height)", "codec": codecName,
    "captured": capturedN, "encoded": encoded, "encode_backlog": capturedN - encoded - encodeErrors,
    "encode_errors": encodeErrors, "capture_drops": drops, "capture_gaps": gaps,
    "ring_s": r3(vring.count > 1 ? vring.last!.t - vring.first!.t + FD : 0),
    "ring_mb": ringBytes / 1_000_000, "latency_ms": latency * 1000, "dir": outDir.path,
    "audio": audioDev?.localizedName ?? "off",
  ]
  let volume = FileManager.default.fileExists(atPath: outDir.path) ? outDir : outDir.deletingLastPathComponent()
  if let free = try? volume.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage {
    o["disk_free_gb"] = r3(Double(free) / 1e9)
  }
  if vring.count > 30 {
    let n = vring.count - 1
    o["fps_measured"] = r3(Double(n) / (vring.last!.t - vring.first!.t))
  }
  if let c = clip { o["recording"] = c.info() }
  if let l = history.last { o["last_clip"] = l }
  return o
}

func route(_ conn: NWConnection, _ path: String, _ q: [String: String], _ arrival: Double) {
  switch path {
  case "/status":
    respond(conn, 200, status())
  case "/start":
    if let c = clip { respond(conn, 409, ["error": "already recording \(c.name)"]); return }
    guard vfmt != nil else { respond(conn, 503, ["error": "camera not delivering frames yet"]); return }
    let cmd = requestTime(q, arrival)
    let reqIn = cmd + latency
    if let o = vring.first, reqIn < o.t - FD / 2 {
      respond(conn, 400, ["error": String(format: "in-point is %.2f s back; the ring holds %.2f s", hostNow() - reqIn, vring.last!.t - o.t)])
      return
    }
    let (name, url) = clipURL(q["name"])
    let c = Clip(name: name, url: url, cmdIn: cmd, reqIn: reqIn)
    if let d = q["duration"], let dur = Double(d), dur > 0 { c.reqOut = reqIn + dur; c.cmdOut = cmd + dur }
    clip = c
    log("clip \(name): start, in-point \(iso(hostToWall(cmd)))\(c.reqOut != nil ? ", duration \(q["duration"]!) s" : "")")
    for f in vring where f.t >= reqIn - FD / 2 { c.feed(f) }
    if q["wait"] == "1" && c.reqOut != nil { c.waiters.append(conn) } else { respond(conn, 200, c.info()) }
  case "/stop":
    guard let c = clip, !c.finishing else { respond(conn, 409, ["error": "not recording"]); return }
    let cmd = requestTime(q, arrival)
    let out = cmd + latency
    if out <= c.reqIn + FD / 2 { respond(conn, 400, ["error": "out-point is not after the in-point"]); return }
    log("clip \(c.name): stop, out-point \(iso(hostToWall(cmd)))")
    c.waiters.append(conn)
    c.stop(cmd: cmd, out: out)
  case "/mark":
    guard let c = clip else { respond(conn, 409, ["error": "not recording"]); return }
    let t = requestTime(q, arrival) + latency
    var m: [String: Any] = ["label": q["label"] ?? "", "wall": iso(hostToWall(t - latency))]
    if let f = c.first { m["offset_s"] = r3(t - f.t) }
    c.marks.append(m)
    respond(conn, 200, m)
  case "/latency":
    if let s = q["ms"], let ms = Double(s) { latency = ms / 1000 }
    respond(conn, 200, ["latency_ms": latency * 1000])
  case "/clips":
    respond(conn, 200, listClips())
  case "/reveal":
    // only a clip in the output folder, shown in Finder
    let url = outDir.appendingPathComponent((q["name"] ?? "") + ".mov").standardizedFileURL
    guard url.deletingLastPathComponent() == outDir.standardizedFileURL,
          FileManager.default.fileExists(atPath: url.path) else { respond(conn, 404, ["error": "no such clip"]); return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-R", url.path]
    try? p.run()
    respond(conn, 200, ["revealed": url.path])
  case "/quit":
    respond(conn, 200, ["quit": true])
    if let c = clip, !c.finishing {
      quitAfterClip = true
      c.stop(cmd: arrival, out: arrival + latency)
    } else {
      sq.asyncAfter(deadline: .now() + 0.2) { exit(0) }
    }
  default:
    respond(conn, 404, ["error": "unknown path \(path)",
                        "paths": ["/", "/status", "/clips", "/preview.jpg", "/start", "/stop", "/mark", "/reveal", "/latency", "/quit"]])
  }
}

let hq = DispatchQueue(label: "pocketcam.http")
let params = NWParameters.tcp
params.requiredInterfaceType = .loopback
params.allowLocalEndpointReuse = true
let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
listener.newConnectionHandler = { conn in
  conn.start(queue: hq)
  conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
    let arrival = hostNow()
    guard let data, let s = String(data: data, encoding: .utf8) else { conn.cancel(); return }
    let lines = s.components(separatedBy: "\r\n")
    let parts = lines[0].split(separator: " ")
    guard parts.count >= 2, let comps = URLComponents(string: "http://h" + parts[1]) else {
      respond(conn, 400, ["error": "bad request"]); return
    }
    var headers: [String: String] = [:]
    for l in lines.dropFirst() {
      if l.isEmpty { break }
      if let i = l.firstIndex(of: ":") {
        headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
      }
    }
    // A web page on another site can make the browser send requests here, and
    // a rebound DNS name can make them look same-origin: only this host's own
    // names are accepted, and anything that changes state must be a POST.
    let hosts = ["127.0.0.1:\(port)", "localhost:\(port)"]
    if let h = headers["host"], !hosts.contains(h) { respond(conn, 403, ["error": "host \(h) not allowed"]); return }
    if let o = headers["origin"], !hosts.map({ "http://" + $0 }).contains(o) {
      respond(conn, 403, ["error": "origin \(o) not allowed"]); return
    }
    let path = comps.path
    let changes: Set<String> = ["/start", "/stop", "/mark", "/reveal", "/latency", "/quit"]
    if changes.contains(path) && parts[0] != "POST" { respond(conn, 405, ["error": "\(path) takes POST"]); return }
    // form encoding: browsers and URLSearchParams write a space as "+"
    var q: [String: String] = [:]
    for i in comps.percentEncodedQueryItems ?? [] {
      let v = (i.value ?? "").replacingOccurrences(of: "+", with: " ")
      q[i.name] = v.removingPercentEncoding ?? v
    }
    switch path {
    case "/", "/index.html":
      if !webDir.isEmpty, let html = FileManager.default.contents(atPath: webDir + "/index.html") {
        respondData(conn, 200, "text/html; charset=utf-8", html)
      } else {
        respond(conn, 404, ["error": "no web page; start with `bun pocketcam.ts serve`, which passes --web"])
      }
    case "/preview.jpg":
      let w = min(max(Int(q["w"] ?? "960") ?? 960, 160), 1920)
      cq.async { previewWaiters.append((conn, w)) }
    default:
      sq.async { route(conn, path, q, arrival) }
    }
  }
}
listener.stateUpdateHandler = { st in
  if case .ready = st { log("control: http://127.0.0.1:\(port)  clips → \(outDir.path)") }
  if case .failed(let e) = st { log("control port \(port): \(e)"); exit(7) }
}
listener.start(queue: hq)

// drain clip queues that waited on the writer or on audio, and print a heartbeat
let tick = DispatchSource.makeTimerSource(queue: sq)
var ticks = 0
tick.schedule(deadline: .now() + 0.02, repeating: 0.02)
tick.setEventHandler {
  clip?.drain()
  ticks += 1
  if ticks % 500 == 0 {
    let s = status()
    var line = "\(s["fps_measured"] ?? "-") fps · ring \(s["ring_s"]!) s / \(s["ring_mb"]!) MB · drops \(s["capture_drops"]!) · gaps \(s["capture_gaps"]!) · backlog \(s["encode_backlog"]!)"
    if let c = clip, let f = c.first { line += String(format: " · REC %@ %.1f s", c.name, hostNow() - f.t) }
    log(line)
  }
}
tick.resume()

signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: sq)
sigint.setEventHandler {
  if let c = clip, !c.finishing, c.writer != nil {
    log("Ctrl-C: closing \(c.name) first")
    quitAfterClip = true
    let now = hostNow()
    c.stop(cmd: now, out: now + latency)
  } else { exit(0) }
}
sigint.resume()

dispatchMain()
