import Testing
@testable import CHSharedKit
import Foundation

/// Tapping a backup presents the share sheet for that backup; the sheet is
/// driven by the selection itself, so it can never open empty.
struct CHBackupListSheetTests {
    @Test func backupFileInfoIsIdentifiableByURL() {
        let a = BackupFileInfo(url: URL(fileURLWithPath: "/tmp/Stash_Backup_1.stashbackup"), creationDate: Date(), fileSize: 1)
        let b = BackupFileInfo(url: URL(fileURLWithPath: "/tmp/Stash_Backup_1.stashbackup"), creationDate: Date(), fileSize: 1)
        let c = BackupFileInfo(url: URL(fileURLWithPath: "/tmp/Stash_Backup_2.stashbackup"), creationDate: Date(), fileSize: 1)
        #expect(a.id == b.id, "the same file is one item for sheet(item:)")
        #expect(a.id != c.id)
        #expect(a.displayName == "Stash_Backup_1")
    }
}
