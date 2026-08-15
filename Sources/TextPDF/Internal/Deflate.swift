//
//  Deflate.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  Zlib streams, for the images a PDF cannot take raw.
//
//  A JPEG goes into a PDF exactly as it arrived, because `/DCTDecode` is the
//  same compression the file already uses. Nothing else does: a PNG's pixels
//  have to be handed over as `/FlateDecode`, which is zlib.
//
//  The system provides the deflate. What it does not provide is the zlib
//  wrapper — Apple's `COMPRESSION_ZLIB` produces the raw stream of RFC 1951,
//  and a PDF reader expects the framed one of RFC 1950. The frame is two
//  header bytes and an Adler-32 of the input, which is the whole of this file.
//

import Compression
import Foundation

enum Deflate {

    /// Compresses to a zlib stream, or returns `nil` when it would not help.
    ///
    /// Returning nil rather than throwing: a PDF is allowed to carry an image
    /// with no filter at all, so failing to compress is a size problem and
    /// never a correctness one.
    static func zlib(_ input: Data) -> Data? {
        guard !input.isEmpty else { return nil }

        let bytes = [UInt8](input)
        // Deflate can expand incompressible input. The margin is what zlib
        // itself documents as the worst case, plus room for the frame.
        let capacity = bytes.count + (bytes.count / 100) + 128
        var compressed = [UInt8](repeating: 0, count: capacity)

        let written = bytes.withUnsafeBufferPointer { source in
            compression_encode_buffer(
                &compressed, capacity,
                source.baseAddress!, bytes.count,
                nil, COMPRESSION_ZLIB
            )
        }
        guard written > 0, written < bytes.count else { return nil }

        // 0x78 0x9C: deflate, 32K window, default compression.
        var out = Data([0x78, 0x9C])
        out.append(contentsOf: compressed[0..<written])
        out.append(contentsOf: adler32(bytes).bigEndianBytes)
        return out
    }

    /// The checksum a zlib stream ends with.
    private static func adler32(_ bytes: [UInt8]) -> UInt32 {
        // The largest number of bytes that can be summed before the modulo is
        // needed. Deferring it is most of why this is fast enough to run on a
        // few megabytes of pixels.
        let base: UInt32 = 65521
        var a: UInt32 = 1
        var b: UInt32 = 0
        var index = 0

        while index < bytes.count {
            let end = min(index + 5552, bytes.count)
            for byte in bytes[index..<end] {
                a &+= UInt32(byte)
                b &+= a
            }
            a %= base
            b %= base
            index = end
        }
        return (b << 16) | a
    }
}
