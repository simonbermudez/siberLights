import AppKit

/// Polls the Music app's playback state via AppleScript so effects can react
/// to "now playing". Needs the Automation TCC grant for Music.app; `noPermission`
/// mirrors that state so the UI can surface it. Never launches Music — it only
/// asks if Music is already running.
final class AppleMusicWatcher {
    private(set) var isPlaying = false
    private(set) var noPermission = false

    private static let source = """
    if application id "com.apple.Music" is running then
        tell application id "com.apple.Music" to player state as string
    else
        "not running"
    end if
    """

    /// Cheap to call frequently from a poll timer.
    func refresh() {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first != nil else {
            isPlaying = false
            noPermission = false
            return
        }
        var errorInfo: NSDictionary?
        let result = NSAppleScript(source: Self.source)?.executeAndReturnError(&errorInfo)
        if let errorInfo, (errorInfo[NSAppleScript.errorNumber] as? Int) == -1743 {
            noPermission = true
            isPlaying = false
            return
        }
        noPermission = false
        isPlaying = result?.stringValue == "playing"
    }
}
