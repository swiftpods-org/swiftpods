import Foundation
import Security

enum ManifestSignature {
    static func launcherCertificate() throws -> SecCertificate? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            throw Diagnostic("SP-RUNTIME-SIGNATURE", stage: "runtime", "Cannot inspect launcher code signature")
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            throw Diagnostic("SP-RUNTIME-SIGNATURE", stage: "runtime", "Cannot inspect static launcher signature")
        }
        var information: CFDictionary?
        let result = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        if result == errSecCSUnsigned { return nil }
        guard result == errSecSuccess, let fields = information as? [String: Any] else {
            throw Diagnostic("SP-RUNTIME-SIGNATURE", stage: "runtime", "Cannot read launcher signing information")
        }
        return (fields[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first
    }

    static func verify(_ signature: Data, content: Data, certificate: SecCertificate) throws {
        func failure() -> Diagnostic { Diagnostic("SP-RUNTIME-SIGNATURE", stage: "runtime", "Compatibility manifest has an invalid/untrusted CMS signature or a different signer") }
        guard !signature.isEmpty else { throw failure() }
        var reference: CMSDecoder?
        guard CMSDecoderCreate(&reference) == errSecSuccess, let decoder = reference else { throw failure() }
        let updated = signature.withUnsafeBytes { bytes in CMSDecoderUpdateMessage(decoder, bytes.baseAddress!, bytes.count) }
        guard updated == errSecSuccess, CMSDecoderFinalizeMessage(decoder) == errSecSuccess else { throw failure() }
        var signer: SecCertificate?
        guard CMSDecoderCopySignerCert(decoder, 0, &signer) == errSecSuccess, let signer,
              SecCertificateCopyData(signer) as Data == SecCertificateCopyData(certificate) as Data else { throw failure() }
        guard let policy = SecPolicyCreateWithProperties(kSecPolicyAppleCodeSigning, nil) else { throw failure() }
        var status = CMSSignerStatus(rawValue: 0)!
        var trust: SecTrust?
        var trustResult: OSStatus = errSecSuccess
        guard CMSDecoderCopySignerStatus(decoder, 0, policy, true, &status, &trust, &trustResult) == errSecSuccess,
              status.rawValue == 1, trustResult == errSecSuccess else { throw failure() }
        var decoded: CFData?
        guard CMSDecoderCopyContent(decoder, &decoded) == errSecSuccess, let decoded, decoded as Data == content else { throw failure() }
    }
}
