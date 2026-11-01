import Foundation

struct PermissionInfo: Sendable, Equatable {
    /// Permission bits including setuid/setgid/sticky (`st_mode & 0o7777`).
    var mode: UInt16
    var owner: String
    var group: String
    var locked: Bool
    var isDirectory: Bool
    var isSymlink: Bool
    var ownedByCurrentUser: Bool

    var symbolic: String { PermissionsService.symbolic(mode, isDirectory: isDirectory) }
    var octal: String { String(mode & 0o777, radix: 8) }
}

enum PermissionsService {
    static func read(_ path: String) -> PermissionInfo? {
        var info = stat()
        guard path.withCString({ lstat($0, &info) }) == 0 else { return nil }
        let type = info.st_mode & S_IFMT
        return PermissionInfo(
            mode: UInt16(info.st_mode & 0o7777),
            owner: userName(info.st_uid),
            group: groupName(info.st_gid),
            locked: info.st_flags & UInt32(UF_IMMUTABLE) != 0,
            isDirectory: type == S_IFDIR,
            isSymlink: type == S_IFLNK,
            ownedByCurrentUser: info.st_uid == getuid()
        )
    }

    /// `rwxr-xr-x` style string, with `d` prefix for folders and s/t for special bits.
    static func symbolic(_ mode: UInt16, isDirectory: Bool) -> String {
        func triad(_ bits: UInt16, special: Bool, specialChar: Character) -> String {
            let r: Character = bits & 4 != 0 ? "r" : "-"
            let w: Character = bits & 2 != 0 ? "w" : "-"
            var x: Character = bits & 1 != 0 ? "x" : "-"
            if special { x = bits & 1 != 0 ? specialChar : Character(specialChar.uppercased()) }
            return String([r, w, x])
        }
        return (isDirectory ? "d" : "-")
            + triad((mode >> 6) & 7, special: mode & 0o4000 != 0, specialChar: "s")
            + triad((mode >> 3) & 7, special: mode & 0o2000 != 0, specialChar: "s")
            + triad(mode & 7, special: mode & 0o1000 != 0, specialChar: "t")
    }

    /// Parses a 3- or 4-digit octal string ("755", "0644").
    static func parseOctal(_ text: String) -> UInt16? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard (3...4).contains(trimmed.count), trimmed.allSatisfy({ ("0"..."7").contains($0) }),
              let value = UInt16(trimmed, radix: 8) else { return nil }
        return value
    }

    /// Applies `mode` (rwx bits; special bits are kept from each item) and the locked flag.
    /// With `recursive`, enclosed folders get `mode` as-is; enclosed files get it too, minus the
    /// execute bits unless the file was already executable, so documents never become runnable.
    static func apply(paths: [String], mode: UInt16?, locked: Bool?, recursive: Bool) -> OpResult {
        var changed = 0
        var firstError: String?
        func note(_ path: String, _ code: Int32) {
            if firstError == nil {
                let reason = code == EPERM
                    ? "You don’t have permission to change “\(PathTools.basename(path))”. Only its owner can change it."
                    : "“\(PathTools.basename(path))”: \(String(cString: strerror(code)))"
                firstError = reason
            }
        }

        for path in paths {
            if setOne(path, mode: mode, locked: locked, preserveExecute: false, note: note) { changed += 1 }
            guard recursive, let info = read(path), info.isDirectory, !info.isSymlink else { continue }
            // Lazy enumerator keeps memory flat for large trees; symlinks are never followed.
            let enumerator = FileManager.default.enumerator(atPath: path)
            while let relative = enumerator?.nextObject() as? String {
                let child = (path as NSString).appendingPathComponent(relative)
                var info = stat()
                guard child.withCString({ lstat($0, &info) }) == 0, info.st_mode & S_IFMT != S_IFLNK else { continue }
                let isDirectory = info.st_mode & S_IFMT == S_IFDIR
                if setOne(child, mode: mode, locked: locked, preserveExecute: !isDirectory, note: note) { changed += 1 }
            }
        }
        if let firstError, changed == 0 { return .failure(firstError) }
        var result = OpResult.success(count: changed)
        result.error = firstError
        return result
    }

    private static func setOne(
        _ path: String,
        mode: UInt16?,
        locked: Bool?,
        preserveExecute: Bool,
        note: (String, Int32) -> Void
    ) -> Bool {
        var info = stat()
        guard path.withCString({ lstat($0, &info) }) == 0 else {
            note(path, errno)
            return false
        }
        let wasLocked = info.st_flags & UInt32(UF_IMMUTABLE) != 0
        let wantLocked = locked ?? wasLocked
        // A locked item rejects chmod, so unlock first and re-lock afterwards if requested.
        if wasLocked, mode != nil || !wantLocked {
            guard chflags(path, info.st_flags & ~UInt32(UF_IMMUTABLE)) == 0 else {
                note(path, errno)
                return false
            }
        }
        var ok = true
        if let mode {
            let current = UInt16(info.st_mode & 0o7777)
            var target = (current & 0o7000) | (mode & 0o777)
            if preserveExecute && current & 0o111 == 0 { target &= ~0o111 }
            if target != current, chmod(path, mode_t(target)) != 0 {
                note(path, errno)
                ok = false
            }
        }
        if wantLocked, mode != nil || !wasLocked {
            if chflags(path, (info.st_flags & ~UInt32(UF_IMMUTABLE)) | UInt32(UF_IMMUTABLE)) != 0 {
                note(path, errno)
                ok = false
            }
        }
        return ok
    }

    private static func userName(_ uid: uid_t) -> String {
        guard let pw = getpwuid(uid), let name = pw.pointee.pw_name else { return "\(uid)" }
        return String(cString: name)
    }

    private static func groupName(_ gid: gid_t) -> String {
        guard let gr = getgrgid(gid), let name = gr.pointee.gr_name else { return "\(gid)" }
        return String(cString: name)
    }
}
