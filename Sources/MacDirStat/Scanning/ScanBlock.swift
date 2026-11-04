import Foundation

/// Why a folder's contents could not be read.
///
/// The app only reports folders that need a person's attention. A folder whose
/// own permission bits exclude this user can never be read by the app, Full Disk
/// Access or not, so reporting it as "incomplete" produces a permanent warning
/// that no action can resolve. macOS protects many system folders without any
/// permission-bit hint (`Operation not permitted` on a `drwxrwxrwx` folder), and
/// those are what Full Disk Access is for; they stay reportable.
struct ScanBlock {
    enum Kind {
        /// Permissions on the folder itself exclude this user; nothing the user
        /// changes in System Settings will help.
        case permissions
        /// macOS denied access despite permissions allowing it (TCC, SIP, or a
        /// restricted system location).
        case systemProtected
        /// Cloud-only: reading would download the contents.
        case cloudOnly
        /// The folder changed while it was being scanned.
        case changedMidScan
        /// A synthetic mirror of a volume that is scanned separately.
        case syntheticDuplicate
        /// Anything else worth surfacing (I/O errors, unmounted paths).
        case other
    }

    let kind: Kind
    /// Text shown in the tree and the inspector.
    let message: String
    /// Optional extra detail for the inspector; nil for the common cases.
    var detail: String?

    init(kind: Kind, message: String, detail: String? = nil) {
        self.kind = kind
        self.message = message
        self.detail = detail
    }

    /// Whether this block counts toward the "contents not included" warning.
    var countsAsIncomplete: Bool {
        switch kind {
        case .permissions, .cloudOnly, .syntheticDuplicate:
            // Expected, permanent conditions: nothing the user can change would
            // make these readable, and the data is either absent by design or
            // measured from its real location.
            return false
        case .systemProtected, .changedMidScan, .other:
            return true
        }
    }

    /// A short label for the tree row, or nil when there is nothing actionable.
    var shortLabel: String? {
        switch kind {
        case .permissions:
            return "Folder readable only as root; not scanned"
        case .cloudOnly:
            return "Cloud-only folder; contents not downloaded"
        case .systemProtected:
            return "Protected by macOS; Full Disk Access may be required"
        case .changedMidScan:
            return "Folder changed during the scan; rescan to measure it"
        case .syntheticDuplicate:
            return "Measured from /System/Volumes/Data; this copy is skipped"
        case .other:
            return message
        }
    }

    static let permissions = ScanBlock(
        kind: .permissions,
        message: "Only this folder's owner or root can open it, so its contents are not included. That is normal for daemon-private system folders and is not a Full Disk Access problem."
    )

    static let changedMidScan = ScanBlock(
        kind: .changedMidScan,
        message: "Folder changed during the scan; rescan to measure its contents."
    )

    static let cloudOnly = ScanBlock(
        kind: .cloudOnly,
        message: "Cloud-only folder: contents were not downloaded or scanned."
    )

    /// Classifies a failed `open` of a directory.
    ///
    /// `EPERM` is what macOS returns when a system protection (TCC/SIP) blocks
    /// the open even though the mode bits allow it, and `EACCES` means the mode
    /// bits excluded this process. The check against the folder's own bits makes
    /// that distinction explicit so a plain `chmod 700 root:wheel` folder does
    /// not get blamed on Full Disk Access.
    static func forOpenFailure(errno code: Int32, path: String) -> ScanBlock {
        switch code {
        case EACCES:
            return permissionDenied(path: path)
        case EPERM:
            return ScanBlock(
                kind: .systemProtected,
                message: "macOS prevented access to this folder (\(path)). If you expect this data to be included, grant Full Disk Access and rescan.",
                detail: "Operation not permitted"
            )
        case EDEADLK:
            return ScanBlock(
                kind: .cloudOnly,
                message: "Cloud folder needs a download to enumerate; contents were not scanned."
            )
        case EIO, ENXIO, ENODEV:
            return ScanBlock(
                kind: .other,
                message: "The storage device holding this folder reported an I/O error (\(String(cString: strerror(code)))); its contents could not be read."
            )
        default:
            return ScanBlock(
                kind: .other,
                message: "Contents could not be read: \(Self.describe(code))."
            )
        }
    }

    static func forFailure(errno code: Int32) -> ScanBlock {
        switch code {
        case EACCES:
            return permissionDenied(path: nil)
        case EPERM:
            return ScanBlock(
                kind: .systemProtected,
                message: "macOS prevented access while listing this folder.",
                detail: "Operation not permitted"
            )
        case EDEADLK:
            return ScanBlock(
                kind: .cloudOnly,
                message: "Cloud folder needs a download to enumerate; contents were not scanned."
            )
        default:
            return ScanBlock(
                kind: .other,
                message: "Contents could not be read: \(Self.describe(code))."
            )
        }
    }

    /// True when `path` is root-owned and macOS's own permission bits deny
    /// this account — the normal case for daemon-private folders. Supplementary
    /// groups count: the app runs with the user's full group list, and several
    /// macOS groups (`admin`, `_lpadmin`) do grant access to some of these.
    static func isOwnerOnly(_ path: String) -> Bool {
        var info = Darwin.stat()
        guard lstat(path, &info) == 0 else { return false }
        let mode = info.st_mode
        let isOwner = info.st_uid == getuid()
        // Supplementary groups count: several macOS groups actually do grant
        // access to folders that the primary group alone would deny.
        let inGroup = memberOfGroup(info.st_gid)
        let canRead: Bool
        if isOwner {
            canRead = mode & S_IRUSR != 0
        } else if inGroup {
            canRead = mode & S_IRGRP != 0
        } else {
            canRead = mode & S_IROTH != 0
        }
        let canSearch: Bool
        if isOwner {
            canSearch = mode & S_IXUSR != 0
        } else if inGroup {
            canSearch = mode & S_IXGRP != 0
        } else {
            canSearch = mode & S_IXOTH != 0
        }
        return !(canRead && canSearch)
    }

    /// Checks the process's real supplementary groups, which `getgid()` misses.
    static func memberOfGroup(_ gid: gid_t) -> Bool {
        if gid == getgid() || gid == getegid() { return true }
        let capacity = getgroups(0, nil)
        guard capacity > 0 else { return false }
        var groups = [gid_t](repeating: 0, count: Int(capacity))
        let count = Int(getgroups(capacity, &groups))
        guard count > 0 else { return false }
        return groups[0..<count].contains(gid)
    }

    private static func permissionDenied(path: String?) -> ScanBlock {
        // Distinguish "this account simply can't read it" from a protection
        // layer that reports EACCES on a folder the bits do allow.
        if let path, !isOwnerOnly(path) {
            return ScanBlock(
                kind: .systemProtected,
                message: "macOS denied access to this folder (\(path)). Its permissions allow reading, so a system protection is blocking it; Full Disk Access may help.",
                detail: "Permission denied"
            )
        }
        return permissions
    }

    static func describe(_ code: Int32) -> String {
        let text = String(cString: strerror(code))
        return text.isEmpty ? "errno \(code)" : text
    }
}
