import Foundation
import AVFoundation
import CoreImage

struct ActivitySegment {
    enum Activity {
        case active
        case idle
        case click
    }

    let activity: Activity
    let startTime: TimeInterval
    let endTime: TimeInterval

    var duration: TimeInterval { endTime - startTime }
}

struct ActivityAnalyzer {
    static let idleThreshold: TimeInterval = 1.5
    static let clickWindowRadius: TimeInterval = 0.15

    /// Analyze with both input events AND screen change detection
    static func analyzeWithScreenChanges(
        events: [LoggedEvent],
        videoURL: URL,
        duration: TimeInterval
    ) async -> [ActivitySegment] {
        let inputSegments = analyze(events: events, duration: duration)

        // Pre-scan video for screen changes
        guard let screenIdle = await scanScreenChanges(videoURL: videoURL, duration: duration) else {
            return inputSegments
        }

        // Merge: a segment is idle if input says idle OR screen says idle
        return mergeSegments(input: inputSegments, screenIdle: screenIdle, duration: duration)
    }

    /// Fast pre-scan: read frames at ~2fps, compare consecutive frames, build idle regions
    private static func scanScreenChanges(videoURL: URL, duration: TimeInterval) async -> [(start: TimeInterval, end: TimeInterval)]? {
        let asset = AVURLAsset(url: videoURL)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return nil }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch { return nil }

        // Read at very low resolution for speed
        let readerSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 160,
            kCVPixelBufferHeightKey as String: 90,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: readerSettings)
        reader.add(output)
        reader.startReading()

        let sampleInterval = 0.5  // check every 0.5s
        let sourceFPS = (try? await track.load(.nominalFrameRate)) ?? 30
        let frameSkip = max(1, Int(Double(sourceFPS) * sampleInterval))
        let changeThreshold: Float = 0.005  // < 0.5% pixel change = static

        var prevData: [UInt8]?
        var frameIndex = 0
        var staticStart: TimeInterval?
        var idleRegions: [(start: TimeInterval, end: TimeInterval)] = []

        while let sampleBuffer = output.copyNextSampleBuffer() {
            frameIndex += 1
            guard frameIndex % frameSkip == 0 else { continue }

            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }

            // Extract raw pixel data at low res
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { continue }

            let totalBytes = height * bytesPerRow
            let currentData = [UInt8](UnsafeBufferPointer(
                start: baseAddress.assumingMemoryBound(to: UInt8.self),
                count: totalBytes
            ))

            if let prev = prevData, prev.count == currentData.count {
                // Compare frames — mean absolute difference
                var diff: Int = 0
                let pixelCount = width * height
                let stride = max(1, totalBytes / pixelCount)
                for i in Swift.stride(from: 0, to: min(prev.count, currentData.count), by: stride * 4) {
                    diff += abs(Int(currentData[i]) - Int(prev[i]))
                }
                let meanDiff = Float(diff) / Float(pixelCount)
                let normalized = meanDiff / 255.0

                if normalized < changeThreshold {
                    // Screen is static
                    if staticStart == nil { staticStart = time - sampleInterval }
                } else {
                    // Screen changed
                    if let start = staticStart {
                        let idleDuration = time - start
                        if idleDuration >= idleThreshold {
                            idleRegions.append((start: start, end: time))
                        }
                        staticStart = nil
                    }
                }
            }
            prevData = currentData
        }

        // Close any open static region
        if let start = staticStart, duration - start >= idleThreshold {
            idleRegions.append((start: start, end: duration))
        }

        reader.cancelReading()
        NSLog("Screenie: Screen change scan found %d idle regions", idleRegions.count)
        return idleRegions
    }

    /// Merge input-based segments with screen-idle regions
    private static func mergeSegments(
        input: [ActivitySegment],
        screenIdle: [(start: TimeInterval, end: TimeInterval)],
        duration: TimeInterval
    ) -> [ActivitySegment] {
        // Build a combined timeline: mark time ranges as idle if screen is static
        // even if input-based analysis says active (but preserve clicks)
        var result: [ActivitySegment] = []

        for segment in input {
            if segment.activity == .click {
                // Always keep clicks as-is
                result.append(segment)
                continue
            }

            if segment.activity == .idle {
                // Already idle — keep it
                result.append(segment)
                continue
            }

            // Active segment — check if screen was static during this time
            var remaining = segment.startTime
            let segEnd = segment.endTime

            for idle in screenIdle {
                // Find overlap between this active segment and screen-idle region
                let overlapStart = max(remaining, idle.start)
                let overlapEnd = min(segEnd, idle.end)

                if overlapStart < overlapEnd && overlapEnd - overlapStart >= idleThreshold {
                    // Add active portion before the overlap
                    if overlapStart > remaining {
                        result.append(ActivitySegment(activity: .active, startTime: remaining, endTime: overlapStart))
                    }
                    // Add idle portion (screen was static even though there was input)
                    result.append(ActivitySegment(activity: .idle, startTime: overlapStart, endTime: overlapEnd))
                    remaining = overlapEnd
                }
            }

            // Add any remaining active portion
            if remaining < segEnd {
                result.append(ActivitySegment(activity: .active, startTime: remaining, endTime: segEnd))
            }
        }

        return result.sorted { $0.startTime < $1.startTime }
    }

    static func analyze(events: [LoggedEvent], duration: TimeInterval) -> [ActivitySegment] {
        guard !events.isEmpty else { return [] }

        let sorted = events.sorted { $0.timestamp < $1.timestamp }

        var segments: [ActivitySegment] = []
        var segmentStart = 0.0
        var lastEventTime = 0.0

        for event in sorted {
            let t = event.timestamp

            if t - lastEventTime > idleThreshold && lastEventTime >= segmentStart {
                if lastEventTime > segmentStart {
                    segments.append(ActivitySegment(
                        activity: .active,
                        startTime: segmentStart,
                        endTime: lastEventTime
                    ))
                }
                segments.append(ActivitySegment(
                    activity: .idle,
                    startTime: lastEventTime,
                    endTime: t
                ))
                segmentStart = t
            }

            if event.type == .mouseClick {
                if t > segmentStart + clickWindowRadius {
                    segments.append(ActivitySegment(
                        activity: .active,
                        startTime: segmentStart,
                        endTime: t - clickWindowRadius
                    ))
                }
                segments.append(ActivitySegment(
                    activity: .click,
                    startTime: t - clickWindowRadius,
                    endTime: t + clickWindowRadius
                ))
                segmentStart = t + clickWindowRadius
            }

            lastEventTime = t
        }

        if lastEventTime > segmentStart {
            segments.append(ActivitySegment(
                activity: .active,
                startTime: segmentStart,
                endTime: lastEventTime
            ))
        }

        if lastEventTime < duration - idleThreshold {
            segments.append(ActivitySegment(
                activity: .idle,
                startTime: lastEventTime,
                endTime: duration
            ))
        } else if lastEventTime < duration {
            segments.append(ActivitySegment(
                activity: .active,
                startTime: lastEventTime,
                endTime: duration
            ))
        }

        return segments
    }
}
