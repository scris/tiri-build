import Foundation
import Security

/// The code signing questions an update asks, put to the Security framework directly, as Sparkle's SUCodeSigningVerifier
/// does: is the new app what the installed one's own designated requirement describes.
public enum SigningCheck {
    /// The designated requirement says who may stand in for an app: its identifier, its maker, and for a Developer ID
    /// app the kind of certificate. It's what macOS itself uses to decide an app is the same app.
    public static func meetsDesignatedRequirement(of installed: URL, _ new: URL) -> Bool {
        var installedCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(installed as CFURL, [], &installedCode) == errSecSuccess, let installedCode else { return false }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(installedCode, [], &requirement) == errSecSuccess, let requirement else { return false }
        var newCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(new as CFURL, [], &newCode) == errSecSuccess, let newCode else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(newCode, flags, requirement) == errSecSuccess
    }
}
