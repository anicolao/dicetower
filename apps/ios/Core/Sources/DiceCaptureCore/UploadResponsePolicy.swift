import Foundation

public enum UploadResponsePolicy {
    public static func isPermanentRejection(status: Int, message: String, authenticationRefreshed: Bool) -> Bool {
        if [400,403,413,422].contains(status) { return true }
        // RTDB rules failures use 401 too. Never classify an ordinary expired
        // token as a permanently bad record; first retry with refreshed auth.
        return status == 401 && authenticationRefreshed && message.lowercased().contains("permission denied")
    }
}
