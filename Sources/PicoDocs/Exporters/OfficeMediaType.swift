//
//  OfficeMediaType.swift
//  PicoDocs
//
//  Shared mapping between image file extensions and MIME types, used by both the
//  read side (`WordConverter`, when stamping `metadata["mimeType"]` on extracted
//  images) and the write side (the OOXML exporters, when declaring media content
//  types), so the two agree.
//

import Foundation

enum OfficeMediaType {

    /// The MIME type for a media file extension (without the leading dot).
    static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "bmp": return "image/bmp"
        case "tif", "tiff": return "image/tiff"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "emf": return "image/emf"
        case "wmf": return "image/wmf"
        default: return "application/octet-stream"
        }
    }

    /// The file extension (without the dot) for an image MIME type. Inverse of
    /// `mimeType(forExtension:)`, used when writing media whose carrier only knows
    /// its MIME type (e.g. a `DocumentSection` image with `metadata["mimeType"]`).
    static func fileExtension(forMIME mime: String) -> String {
        switch mime.lowercased() {
        case "image/png": return "png"
        case "image/jpeg", "image/jpg": return "jpeg"
        case "image/gif": return "gif"
        case "image/bmp": return "bmp"
        case "image/tiff": return "tiff"
        case "image/svg+xml": return "svg"
        case "image/webp": return "webp"
        case "image/emf": return "emf"
        case "image/wmf": return "wmf"
        default: return "bin"
        }
    }
}
