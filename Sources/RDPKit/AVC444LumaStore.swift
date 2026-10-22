import CoreVideo
import Foundation

// AVC destRect bounds an update, while region masks address the coded image.
// Keep the last luma samples at surface coordinates, independent of that bound.
final class RDPAVC444LumaStore<Frame> {
    private struct Key: Hashable {
        var surfaceID: UInt16
        var codecID: UInt16
        var phaseX: Int
        var phaseY: Int
    }

    private struct State {
        var width: Int
        var height: Int
        var codedWidth: Int?
        var codedHeight: Int?
        var frame: Frame
        var coverage: [UInt8]
    }

    private var states: [Key: State] = [:]

    func reset() { states.removeAll() }

    func update(
        surfaceID: UInt16, codecID: UInt16, width: Int, height: Int,
        destinationRect: RDPFrameRect, regionRects: [RDPFrameRect]?, surfaceRect: RDPFrameRect? = nil, frame: Frame,
        merge: (Frame?, Int, Int, Frame, Int, Int, Int, Int, [RDPFrameRect]) throws -> Frame
    ) throws {
        let sourceOrigin = rdpAVCSourceOrigin(width: width, height: height,
                                              destinationRect: destinationRect, surfaceRect: surfaceRect)
        let key = Key(surfaceID: surfaceID, codecID: codecID,
                      phaseX: sourceOrigin.x % 2, phaseY: sourceOrigin.y % 2)
        let origin = (x: sourceOrigin.x - key.phaseX, y: sourceOrigin.y - key.phaseY)
        var previous = states[key]
        // A new full coded surface replaces obsolete dimensions, rather than
        // retaining a separate allocation for every size the server has used.
        let isLocal = rdpAVCIsRegionLocal(width: width, height: height,
                                          destinationRect: destinationRect, surfaceRect: surfaceRect)
        if !isLocal, let old = previous, let oldWidth = old.codedWidth, let oldHeight = old.codedHeight,
           oldWidth != width || oldHeight != height
        {
            states = states.filter { $0.key.surfaceID != surfaceID || $0.key.codecID != codecID }
            previous = nil
        }
        let canvasWidth = max(previous?.width ?? 0, width + origin.x)
        let canvasHeight = max(previous?.height ?? 0, height + origin.y)
        let sourceRegions = regionRects.map {
            rdpAVCSourceRegions($0, width: width, height: height, destinationRect: destinationRect,
                                surfaceRect: surfaceRect)
        } ?? [RDPFrameRect(
            left: UInt16(clamping: Int(destinationRect.left) - sourceOrigin.x),
            top: UInt16(clamping: Int(destinationRect.top) - sourceOrigin.y),
            right: UInt16(clamping: Int(destinationRect.right) - sourceOrigin.x),
            bottom: UInt16(clamping: Int(destinationRect.bottom) - sourceOrigin.y)
        )]
        let regions = clippedRegions(sourceRegions, width: width, height: height)
        let merged = try merge(previous?.frame, previous?.width ?? 0, previous?.height ?? 0,
                               frame, width, height, origin.x, origin.y, regions)
        var coverage = [UInt8](repeating: 0, count: canvasWidth * canvasHeight)
        if let previous {
            for row in 0 ..< previous.height {
                coverage.replaceSubrange(row * canvasWidth ..< row * canvasWidth + previous.width,
                                         with: previous.coverage[row * previous.width ..< (row + 1) * previous.width])
            }
        }
        for rect in regions {
            for row in Int(rect.top) ..< Int(rect.bottom) {
                let start = (row + origin.y) * canvasWidth + Int(rect.left) + origin.x
                coverage.replaceSubrange(start ..< start + Int(rect.width),
                                         with: repeatElement(1, count: Int(rect.width)))
            }
        }
        // Different local origins can have different 420 sampling phases.
        // Retain each phase without resampling, and reject stale overlapping
        // samples in the others rather than combining incompatible chroma.
        for otherKey in Array(states.keys) where otherKey != key
            && otherKey.surfaceID == surfaceID && otherKey.codecID == codecID {
            guard var other = states[otherKey] else { continue }
            for rect in regions {
                let left = max(0, Int(rect.left) + sourceOrigin.x - otherKey.phaseX)
                let top = max(0, Int(rect.top) + sourceOrigin.y - otherKey.phaseY)
                let right = min(other.width, Int(rect.right) + sourceOrigin.x - otherKey.phaseX)
                let bottom = min(other.height, Int(rect.bottom) + sourceOrigin.y - otherKey.phaseY)
                guard right > left, bottom > top else { continue }
                for row in top ..< bottom {
                    other.coverage.replaceSubrange(row * other.width + left ..< row * other.width + right,
                                                   with: repeatElement(0, count: right - left))
                }
            }
            states[otherKey] = other
        }
        states[key] = State(width: canvasWidth, height: canvasHeight,
                            codedWidth: isLocal ? previous?.codedWidth : width,
                            codedHeight: isLocal ? previous?.codedHeight : height,
                            frame: merged, coverage: coverage)
    }

    func frame(
        surfaceID: UInt16, codecID: UInt16, width: Int, height: Int,
        destinationRect: RDPFrameRect, regionRects: [RDPFrameRect], surfaceRect: RDPFrameRect? = nil,
        extract: (Frame, Int, Int, Int, Int, Int, Int) throws -> Frame
    ) throws -> Frame {
        let sourceOrigin = rdpAVCSourceOrigin(width: width, height: height,
                                              destinationRect: destinationRect, surfaceRect: surfaceRect)
        let key = Key(surfaceID: surfaceID, codecID: codecID,
                      phaseX: sourceOrigin.x % 2, phaseY: sourceOrigin.y % 2)
        let origin = (x: sourceOrigin.x - key.phaseX, y: sourceOrigin.y - key.phaseY)
        guard let state = states[key] else {
            throw RDPAVC444DecodeError.missingLumaSubframe
        }
        let isLocal = rdpAVCIsRegionLocal(width: width, height: height,
                                          destinationRect: destinationRect, surfaceRect: surfaceRect)
        if !isLocal, let oldWidth = state.codedWidth, let oldHeight = state.codedHeight,
           oldWidth != width || oldHeight != height {
            throw RDPAVC444DecodeError.missingLumaSubframe
        }
        let requested = regionRects.isEmpty ? [destinationRect] : regionRects
        let regions = rdpAVCSourceRegions(requested, width: width, height: height, destinationRect: destinationRect,
                                          surfaceRect: surfaceRect)
        for rect in regions {
            let left = Int(rect.left) + origin.x
            let top = Int(rect.top) + origin.y
            let right = Int(rect.right) + origin.x
            let bottom = Int(rect.bottom) + origin.y
            guard right <= state.width, bottom <= state.height,
                  right > left, bottom > top else {
                throw RDPAVC444DecodeError.missingLumaSubframe
            }
            for row in top ..< bottom {
                guard state.coverage[row * state.width + left ..< row * state.width + right].allSatisfy({ $0 != 0 }) else {
                    throw RDPAVC444DecodeError.missingLumaSubframe
                }
            }
        }
        return try extract(state.frame, state.width, state.height, origin.x, origin.y, width, height)
    }
}

func rdpAVCIsRegionLocal(
    width: Int, height: Int, destinationRect: RDPFrameRect, surfaceRect: RDPFrameRect? = nil
) -> Bool {
    if let surfaceRect, width < Int(surfaceRect.width) || height < Int(surfaceRect.height) {
        return true
    }
    return Int(destinationRect.right) > width || Int(destinationRect.bottom) > height
}

func rdpAVCSourceOrigin(
    width: Int, height: Int, destinationRect: RDPFrameRect, surfaceRect: RDPFrameRect? = nil
) -> (x: Int, y: Int) {
    if rdpAVCIsRegionLocal(width: width, height: height, destinationRect: destinationRect, surfaceRect: surfaceRect) {
        return (Int(destinationRect.left), Int(destinationRect.top))
    }
    return (0, 0)
}

func rdpAVCSourceRegions(
    _ regions: [RDPFrameRect], width: Int, height: Int, destinationRect: RDPFrameRect,
    surfaceRect: RDPFrameRect? = nil
) -> [RDPFrameRect] {
    let origin = rdpAVCSourceOrigin(width: width, height: height, destinationRect: destinationRect, surfaceRect: surfaceRect)
    guard origin.x != 0 || origin.y != 0,
          !regions.allSatisfy({ Int($0.right) <= width && Int($0.bottom) <= height }) else {
        return regions
    }
    return regions.compactMap { rect in
        let left = max(0, Int(rect.left) - origin.x)
        let top = max(0, Int(rect.top) - origin.y)
        let right = max(0, Int(rect.right) - origin.x)
        let bottom = max(0, Int(rect.bottom) - origin.y)
        guard right > left, bottom > top else { return nil }
        return RDPFrameRect(left: UInt16(left), top: UInt16(top), right: UInt16(right), bottom: UInt16(bottom))
    }
}

private func clippedRegions(_ regions: [RDPFrameRect], width: Int, height: Int) -> [RDPFrameRect] {
    regions.compactMap { rect in
        let left = min(width, Int(rect.left))
        let top = min(height, Int(rect.top))
        let right = min(width, Int(rect.right))
        let bottom = min(height, Int(rect.bottom))
        guard right > left, bottom > top else { return nil }
        return RDPFrameRect(left: UInt16(left), top: UInt16(top), right: UInt16(right), bottom: UInt16(bottom))
    }
}

func mergeYUV420Frame(
    previous: RDPYUV420Frame?, previousWidth: Int, previousHeight: Int,
    source: RDPYUV420Frame, width: Int, height: Int, originX: Int, originY: Int,
    regions: [RDPFrameRect]
) throws -> RDPYUV420Frame {
    let canvasWidth = max(previousWidth, width + originX)
    let canvasHeight = max(previousHeight, height + originY)
    if previous == nil, originX == 0, originY == 0 { return source }
    var result = try RDPYUV420Frame(width: canvasWidth, height: canvasHeight,
        y: [UInt8](repeating: 0, count: canvasWidth * canvasHeight),
        u: [UInt8](repeating: 128, count: canvasWidth * canvasHeight / 4),
        v: [UInt8](repeating: 128, count: canvasWidth * canvasHeight / 4))
    if let previous {
        copyYUV420Frame(previous, to: &result, sourceX: 0, sourceY: 0, targetX: 0, targetY: 0,
                        width: previousWidth, height: previousHeight)
    }
    for rect in regions {
        copyYUV420Frame(source, to: &result,
                        sourceX: Int(rect.left), sourceY: Int(rect.top),
                        targetX: Int(rect.left) + originX, targetY: Int(rect.top) + originY,
                        width: Int(rect.width), height: Int(rect.height))
    }
    return result
}

func extractYUV420Frame(
    source: RDPYUV420Frame, sourceWidth: Int, sourceHeight: Int,
    originX: Int, originY: Int, width: Int, height: Int
) throws -> RDPYUV420Frame {
    if originX == 0, originY == 0, width == sourceWidth, height == sourceHeight { return source }
    var result = try RDPYUV420Frame(width: width, height: height,
        y: [UInt8](repeating: 0, count: width * height),
        u: [UInt8](repeating: 128, count: width * height / 4),
        v: [UInt8](repeating: 128, count: width * height / 4))
    copyYUV420Frame(source, to: &result, sourceX: originX, sourceY: originY,
                    targetX: 0, targetY: 0, width: min(width, sourceWidth - originX),
                    height: min(height, sourceHeight - originY))
    return result
}

private func copyYUV420Frame(
    _ source: RDPYUV420Frame, to target: inout RDPYUV420Frame,
    sourceX: Int, sourceY: Int, targetX: Int, targetY: Int, width: Int, height: Int
) {
    guard width > 0, height > 0 else { return }
    for row in 0 ..< height {
        let start = (sourceY + row) * source.width + sourceX
        let destination = (targetY + row) * target.width + targetX
        target.y.replaceSubrange(destination ..< destination + width, with: source.y[start ..< start + width])
    }
    let chromaWidth = (sourceX + width + 1) / 2 - sourceX / 2
    for row in sourceY / 2 ..< (sourceY + height + 1) / 2 {
        let start = row * source.width / 2 + sourceX / 2
        let destination = (targetY / 2 + row - sourceY / 2) * target.width / 2 + targetX / 2
        target.u.replaceSubrange(destination ..< destination + chromaWidth, with: source.u[start ..< start + chromaWidth])
        target.v.replaceSubrange(destination ..< destination + chromaWidth, with: source.v[start ..< start + chromaWidth])
    }
}

final class RDPAVC444PixelBufferStore {
    private let store = RDPAVC444LumaStore<CVPixelBuffer>()

    func reset() { store.reset() }

    func update(
        surfaceID: UInt16, codecID: UInt16, imageBuffer: CVPixelBuffer,
        destinationRect: RDPFrameRect, regionRects: [RDPFrameRect]? = nil, surfaceRect: RDPFrameRect? = nil
    ) throws {
        try store.update(surfaceID: surfaceID, codecID: codecID,
                         width: CVPixelBufferGetWidth(imageBuffer), height: CVPixelBufferGetHeight(imageBuffer),
                         destinationRect: destinationRect, regionRects: regionRects, surfaceRect: surfaceRect,
                         frame: imageBuffer, merge: mergePixelBuffers)
    }

    func frame(
        surfaceID: UInt16, codecID: UInt16, width: Int, height: Int,
        destinationRect: RDPFrameRect, regionRects: [RDPFrameRect], surfaceRect: RDPFrameRect? = nil
    ) throws -> CVPixelBuffer {
        try store.frame(surfaceID: surfaceID, codecID: codecID, width: width, height: height,
                        destinationRect: destinationRect, regionRects: regionRects, surfaceRect: surfaceRect,
                        extract: extractPixelBuffer)
    }
}

private func mergePixelBuffers(
    previous: CVPixelBuffer?, previousWidth: Int, previousHeight: Int,
    source: CVPixelBuffer, width: Int, height: Int, originX: Int, originY: Int,
    regions: [RDPFrameRect]
) throws -> CVPixelBuffer {
    let canvasWidth = max(previousWidth, width + originX)
    let canvasHeight = max(previousHeight, height + originY)
    if originX == 0, originY == 0, canvasWidth == width, canvasHeight == height,
       (previous == nil || regions.contains(where: {
           $0.left == 0 && $0.top == 0 && Int($0.right) == width && Int($0.bottom) == height
       }))
    {
        return source
    }
    // Never patch a VideoToolbox buffer or a buffer retained by presentation.
    let result = try makeLumaPixelBuffer(width: canvasWidth, height: canvasHeight,
                                        format: CVPixelBufferGetPixelFormatType(source))
    if let previous {
        try copyNV12(previous, to: result, sourceX: 0, sourceY: 0, targetX: 0, targetY: 0,
                     width: previousWidth, height: previousHeight)
    }
    for rect in regions {
        try copyNV12(source, to: result, sourceX: Int(rect.left), sourceY: Int(rect.top),
                     targetX: Int(rect.left) + originX, targetY: Int(rect.top) + originY,
                     width: Int(rect.width), height: Int(rect.height))
    }
    return result
}

private func extractPixelBuffer(
    source: CVPixelBuffer, sourceWidth: Int, sourceHeight: Int,
    originX: Int, originY: Int, width: Int, height: Int
) throws -> CVPixelBuffer {
    if originX == 0, originY == 0, width == sourceWidth, height == sourceHeight { return source }
    let result = try makeLumaPixelBuffer(width: width, height: height,
                                        format: CVPixelBufferGetPixelFormatType(source))
    try copyNV12(source, to: result, sourceX: originX, sourceY: originY,
                 targetX: 0, targetY: 0, width: min(width, sourceWidth - originX),
                 height: min(height, sourceHeight - originY))
    return result
}

private func makeLumaPixelBuffer(width: Int, height: Int, format: OSType) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
        [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
        &buffer)
    guard status == kCVReturnSuccess, let buffer else {
        throw RDPAVC444DecodeError.coreVideo(operation: "allocate retained luma", status: status)
    }
    return buffer
}

private func copyNV12(
    _ source: CVPixelBuffer, to target: CVPixelBuffer,
    sourceX: Int, sourceY: Int, targetX: Int, targetY: Int, width: Int, height: Int
) throws {
    guard width > 0, height > 0 else { return }
    let sourceStatus = CVPixelBufferLockBaseAddress(source, .readOnly)
    guard sourceStatus == kCVReturnSuccess else {
        throw RDPAVC444DecodeError.coreVideo(operation: "lock retained luma source", status: sourceStatus)
    }
    defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
    let targetStatus = CVPixelBufferLockBaseAddress(target, [])
    guard targetStatus == kCVReturnSuccess else {
        throw RDPAVC444DecodeError.coreVideo(operation: "lock retained luma target", status: targetStatus)
    }
    defer { CVPixelBufferUnlockBaseAddress(target, []) }
    guard CVPixelBufferGetPlaneCount(source) == 2, CVPixelBufferGetPlaneCount(target) == 2 else {
        throw RDPAVC444DecodeError.invalidYUV420Layout
    }
    for plane in 0 ..< 2 {
        guard let sourceBase = CVPixelBufferGetBaseAddressOfPlane(source, plane),
              let targetBase = CVPixelBufferGetBaseAddressOfPlane(target, plane) else {
            throw RDPAVC444DecodeError.missingPixelBufferPlane
        }
        let sourceStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
        let targetStride = CVPixelBufferGetBytesPerRowOfPlane(target, plane)
        let firstRow = plane == 0 ? sourceY : sourceY / 2
        let lastRow = plane == 0 ? sourceY + height : (sourceY + height + 1) / 2
        let destinationRow = plane == 0 ? targetY : targetY / 2
        let sourceColumn = plane == 0 ? sourceX : sourceX / 2 * 2
        let destinationColumn = plane == 0 ? targetX : targetX / 2 * 2
        let byteCount = plane == 0 ? width : ((sourceX + width + 1) / 2 - sourceX / 2) * 2
        for row in firstRow ..< lastRow {
            memcpy(targetBase.advanced(by: (destinationRow + row - firstRow) * targetStride + destinationColumn),
                   sourceBase.advanced(by: row * sourceStride + sourceColumn), byteCount)
        }
    }
}

// Full luma coverage is required before discarding AVC444 regional history;
// an IDR alone resets H264 references but says nothing about the region mask.
func rdpAVCRegionsCover(width: Int, height: Int, regions: [RDPFrameRect]) -> Bool {
    guard width > 0, height > 0 else { return false }
    let rows = Set([0, height] + regions.flatMap { [min(height, Int($0.top)), min(height, Int($0.bottom))] }).sorted()
    for row in rows.dropLast() {
        let intervals = regions.filter { Int($0.top) <= row && Int($0.bottom) > row }
            .sorted { $0.left < $1.left }
        var covered = 0
        for rect in intervals {
            if Int(rect.left) > covered { break }
            covered = max(covered, Int(rect.right))
        }
        if covered < width { return false }
    }
    return true
}
