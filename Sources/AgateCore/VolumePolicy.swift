import Foundation

/// Agate works only with the Mac's internal storage (DESIGN.md 1): no SD
/// cards, USB drives, disk images or network shares.
///
/// The sandbox already limits the app to folders the user chose; this adds
/// the rule that a chosen folder must also live on an internal volume. It
/// reads volume flags from the file system, which is cheap and needs no
/// extra permission.
public enum VolumePolicy {
    public static func isAllowed(_ url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.volumeIsInternalKey, .volumeIsRemovableKey,
                                         .volumeIsEjectableKey, .volumeIsLocalKey]
        guard let values = try? url.resourceValues(forKeys: keys) else {
            // Unknown volume: refuse rather than guess.
            return false
        }
        if values.volumeIsLocal == false { return false }
        if values.volumeIsRemovable == true || values.volumeIsEjectable == true { return false }
        // Internal is nil for some synthetic volumes (the root data volume
        // reports true); treat an explicit false as external.
        return values.volumeIsInternal != false
    }
}
