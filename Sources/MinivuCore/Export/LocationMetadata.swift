import Foundation
import ImageIO

/// Where a photo says it was taken, in every place ImageIO keeps it, so
/// that "Remove location" means all of it: the GPS dictionary (EXIF's GPS
/// directory), its mirror in XMP as `exif:GPS…` tags, and the IPTC place
/// names (city, sub-location, state, country and country code) with their
/// XMP forms in the `photoshop:` and `Iptc4xmpCore:` namespaces, plus IPTC
/// Extension's Location Created and Location Shown.
///
/// Shared by Save As and Batch Convert (S4 in the security review: their
/// "Remove location" option) and by the metadata writer (Edit Metadata's
/// "Remove location"), so the two can never disagree about what a location is.
public enum LocationMetadata {
    /// The XMP namespace of EXIF, where ImageIO mirrors the GPS directory.
    static let exifNamespace = "http://ns.adobe.com/exif/1.0/"

    /// Place-name tags, as XMP paths. ImageIO maps the IPTC dictionary's
    /// City, Province/State and Country/PrimaryLocationName to the
    /// `photoshop:` tags, SubLocation to `Iptc4xmpCore:Location` and the
    /// country code to `Iptc4xmpCore:CountryCode` (all measured).
    static let placeXMPPaths = [
        "photoshop:City", "photoshop:State", "photoshop:Country",
        "Iptc4xmpCore:Location", "Iptc4xmpCore:CountryCode",
        "Iptc4xmpExt:LocationCreated", "Iptc4xmpExt:LocationShown",
    ]

    /// The same in the IPTC property dictionary. (Computed, because CF
    /// strings aren't `Sendable` and can't sit in a static let.)
    static var placeIPTCKeys: [CFString] {
        [kCGImagePropertyIPTCCity, kCGImagePropertyIPTCSubLocation, kCGImagePropertyIPTCProvinceState,
         kCGImagePropertyIPTCCountryPrimaryLocationCode, kCGImagePropertyIPTCCountryPrimaryLocationName,
         kCGImagePropertyIPTCExtLocationCreated, kCGImagePropertyIPTCExtLocationShown]
    }

    /// Removes the GPS dictionary and the IPTC place names from property
    /// dictionaries about to be written. An IPTC dictionary left empty goes too.
    public static func strip(properties: inout [CFString: Any]) {
        properties[kCGImagePropertyGPSDictionary] = nil
        guard var iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] else { return }
        for key in placeIPTCKeys { iptc[key] = nil }
        properties[kCGImagePropertyIPTCDictionary] = iptc.isEmpty ? nil : iptc
    }

    /// Removes every `exif:GPS…` tag and the place-name tags from XMP.
    public static func strip(_ metadata: CGMutableImageMetadata) {
        for path in placeXMPPaths + gpsPaths(in: metadata) {
            CGImageMetadataRemoveTagWithPath(metadata, nil, path as CFString)
        }
    }

    /// The paths of the GPS tags present: whatever ImageIO or another
    /// application mirrored, not a fixed list, so an unusual one (a GPS
    /// processing method, a destination bearing) goes too.
    static func gpsPaths(in metadata: CGImageMetadata) -> [String] {
        (CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] ?? []).compactMap { tag in
            guard CGImageMetadataTagCopyNamespace(tag) as String? == exifNamespace,
                  let name = CGImageMetadataTagCopyName(tag) as String?, name.hasPrefix("GPS"),
                  let prefix = CGImageMetadataTagCopyPrefix(tag) as String? else { return nil }
            return "\(prefix):\(name)"
        }
    }

    /// Whether anything above is present: a GPS dictionary with anything in
    /// it, a `exif:GPS…` tag, or a place name.
    public static func isPresent(properties: [CFString: Any], metadata: CGImageMetadata?) -> Bool {
        if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any], !gps.isEmpty { return true }
        if let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any],
           placeIPTCKeys.contains(where: { iptc[$0] != nil }) { return true }
        guard let metadata else { return false }
        return !gpsPaths(in: metadata).isEmpty
            || placeXMPPaths.contains { CGImageMetadataCopyTagWithPath(metadata, nil, $0 as CFString) != nil }
    }
}
