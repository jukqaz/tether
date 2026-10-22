import Darwin
import Foundation

public enum AppCoordinatorFailure: Error, LocalizedError {
    case alreadyRunning, unsafeLocation, unavailable

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return L("Another Tether instance is already running. Use that instance or quit it before opening this copy.",
                     "다른 Tether가 이미 실행 중입니다. 실행 중인 앱을 사용하거나 종료한 뒤 이 복사본을 열어 주세요.")
        case .unsafeLocation:
            return L("Tether could not verify its local coordination files. No power session was started.",
                     "Tether의 실행 조정 파일을 확인하지 못했습니다. 전원 세션은 시작하지 않았습니다.")
        case .unavailable:
            return L("Tether could not reserve its power coordinator. No power session was started.",
                     "Tether 전원 조정자를 시작하지 못했습니다. 전원 세션은 시작하지 않았습니다.")
        }
    }
}

/// One app writer per user, across builds and bundle copies. The descriptor stays
/// owned until process exit, including quit/update acknowledgement windows. Neither
/// normal shutdown nor command-server restart unlinks or replaces the lock file.
public final class AppCoordinatorLease {
    public static var production: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/" + TetherPaths.bundleID + "/instance.lock").path
    }

    private let descriptor: Int32
    private let path: String
    private let folderDevice: dev_t
    private let folderInode: ino_t
    private let fileDevice: dev_t
    private let fileInode: ino_t
    private let uid: uid_t

    private init(descriptor: Int32, path: String, folder: stat, file: stat) {
        self.descriptor = descriptor; self.path = path
        folderDevice = folder.st_dev; folderInode = folder.st_ino
        fileDevice = file.st_dev; fileInode = file.st_ino; uid = geteuid()
    }

    public static func acquire(at path: String = production) throws -> AppCoordinatorLease {
        guard geteuid() != 0 else { throw AppCoordinatorFailure.unsafeLocation }
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
        var info = stat()
        if lstat(folder, &info) != 0 {
            guard errno == ENOENT, path == production else { throw AppCoordinatorFailure.unsafeLocation }
            let parent = URL(fileURLWithPath: folder).deletingLastPathComponent().path
            if lstat(parent, &info) != 0 {
                guard errno == ENOENT else { throw AppCoordinatorFailure.unsafeLocation }
                let library = URL(fileURLWithPath: parent).deletingLastPathComponent().path
                guard lstat(library, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                      info.st_uid == geteuid(), info.st_mode & 0o022 == 0,
                      mkdir(parent, 0o700) == 0 || errno == EEXIST else { throw AppCoordinatorFailure.unsafeLocation }
            }
            guard lstat(parent, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == geteuid(), info.st_mode & 0o022 == 0 else { throw AppCoordinatorFailure.unsafeLocation }
            guard mkdir(folder, 0o700) == 0 || errno == EEXIST else { throw AppCoordinatorFailure.unavailable }
        }
        guard lstat(folder, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw AppCoordinatorFailure.unsafeLocation }
        let directory = open(folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw AppCoordinatorFailure.unsafeLocation }
        defer { close(directory) }
        var openedFolder = stat()
        guard fstat(directory, &openedFolder) == 0, openedFolder.st_dev == info.st_dev,
              openedFolder.st_ino == info.st_ino else { throw AppCoordinatorFailure.unsafeLocation }
        let fd = openat(directory, URL(fileURLWithPath: path).lastPathComponent,
                        O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AppCoordinatorFailure.unsafeLocation }
        var file = stat()
        guard fstat(fd, &file) == 0, file.st_mode & S_IFMT == S_IFREG,
              file.st_uid == geteuid(), file.st_nlink == 1, file.st_mode & 0o777 == 0o600 else {
            close(fd); throw AppCoordinatorFailure.unsafeLocation
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let busy = errno == EWOULDBLOCK || errno == EAGAIN
            close(fd); throw busy ? AppCoordinatorFailure.alreadyRunning : AppCoordinatorFailure.unavailable
        }
        let lease = AppCoordinatorLease(descriptor: fd, path: path, folder: openedFolder, file: file)
        guard lease.isValid else { throw AppCoordinatorFailure.unsafeLocation }
        return lease
    }

    /// A replaced directory, file, link or permission no longer authorizes writes.
    public var isValid: Bool {
        var folder = stat(), linked = stat(), opened = stat()
        return geteuid() == uid
            && lstat(URL(fileURLWithPath: path).deletingLastPathComponent().path, &folder) == 0
            && folder.st_dev == folderDevice && folder.st_ino == folderInode
            && folder.st_mode & S_IFMT == S_IFDIR && folder.st_uid == uid && folder.st_mode & 0o077 == 0
            && lstat(path, &linked) == 0 && fstat(descriptor, &opened) == 0
            && linked.st_dev == fileDevice && linked.st_ino == fileInode
            && opened.st_dev == fileDevice && opened.st_ino == fileInode
            && linked.st_mode & S_IFMT == S_IFREG && linked.st_uid == uid
            && linked.st_nlink == 1 && linked.st_mode & 0o777 == 0o600
    }

    deinit { close(descriptor) }
}
