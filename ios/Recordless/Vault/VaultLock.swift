import Darwin
import Foundation
import LocalAuthentication
import Observation
import Security

/// Vault lifecycle. There is no passphrase: the notebook unlocks with Face ID
/// (device passcode as fallback) and nothing else.
///
///   - Create: Rust generates a random 32-byte SQLCipher raw key
///     (`generateVaultKey`). A Secure Enclave P-256 key (`.privateKeyUsage +
///     .userPresence`, `WhenPasscodeSetThisDeviceOnly`) wraps it with ECIES; the
///     wrapped blob lives in the keychain (this device only), not in a file.
///   - Unlock: LAContext prompt -> SE decrypt -> `Vault.open` -> wipe the Swift copy.
///   - `.userPresence` (not `.biometryCurrentSet`) so re-enrolling a face does not
///     lock the user out. Removing the device passcode makes iOS destroy both items;
///     the notebook then can't be opened and is set aside, never deleted.
@Observable
@MainActor
final class VaultLock {
    enum State: Equatable {
        case noVault
        case locked
        case unlocked
        /// The vault file exists but its key is gone from this device.
        case keyLost
    }

    private(set) var state: State = .noVault
    private(set) var busy = false
    var error: String?

    private(set) var vault: Vault?
    /// Called (on main) after a note is saved, so a refused lock can be retried.
    @ObservationIgnored var onNoteSaved: (() -> Void)?
    let vaultURL: URL
    private let vaultDir: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        vaultDir = support.appendingPathComponent("vault", isDirectory: true)
        vaultURL = vaultDir.appendingPathComponent("notebook.vault")
        Self.makeProtectedDir(vaultDir)
        refreshState()
    }

    /// Whether a notebook can be created here, and if not, why.
    var createBlocker: String? { VaultKeyWrap.unavailableReason }

    // MARK: Create / unlock

    func create() async {
        guard state == .noVault else { return }
        if let reason = VaultKeyWrap.unavailableReason {
            error = reason
            return
        }
        // Never touch a notebook that is already there (state can be stale).
        refreshState()
        guard state == .noVault else { return }
        await run {
            // Stale items can survive an uninstall; they belong to no vault now.
            VaultKeyWrap.reset()
            let path = self.vaultURL.path
            // Built inside the detached task so the only reference to the
            // lifted `Data` is local there and can be wiped in place; the task
            // result carries the box, not the bytes.
            let key = try await offMain { () throws -> KeyBox in
                var raw = try generateVaultKey()
                return KeyBox(wipingSource: &raw)
            }
            defer { key.wipe() }
            do {
                try VaultKeyWrap.store(key: key)
                let v = try await offMain { try key.withData { try Vault.create(path: path, key: $0) } }
                self.protectVaultFiles()
                self.vault = v
                self.state = .unlocked
            } catch {
                VaultKeyWrap.reset()
                // The file (and journal) was created by this call and holds no
                // notes, but without its key it would read as "key lost" and
                // block creating a notebook. Remove it so state stays .noVault.
                self.removePartialVault()
                self.refreshState()
                throw error
            }
        }
    }

    func unlock() async {
        guard state == .locked else { return }
        guard VaultKeyWrap.hasKey else {
            state = .keyLost
            return
        }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let key = try await VaultKeyWrap.unwrap(reason: "Unlock your notebook")
            defer { key.wipe() }
            let path = vaultURL.path
            let v = try await offMain { try key.withData { try Vault.open(path: path, key: $0) } }
            vault = v
            state = .unlocked
        } catch let e as LAError where [.userCancel, .appCancel, .systemCancel].contains(e.code) {
            // Stay locked; the user can tap Unlock again.
        } catch let e as LAError where e.code == .passcodeNotSet {
            error = VaultKeyWrap.noPasscodeMessage
        } catch VaultKeyWrap.Failure.missing {
            state = .keyLost
        } catch CoreError.Vault(msg: let msg) where msg == "wrong-key" {
            state = .keyLost
        } catch {
            self.error = describe(error)
        }
    }

    func lock() {
        guard state == .unlocked else { return }
        let v = vault
        vault = nil
        state = .locked
        if let v { Task.detached { v.close() } }
    }

    /// Move the unopenable notebook to `vault-set-aside-<time>` (never deleted)
    /// and return to the "no notebook" state so a new one can be created.
    func setAsideAndStartOver() {
        guard state == .keyLost else { return }
        let fm = FileManager.default
        let stamp = Self.stampFormatter.string(from: Date())
        let dest = vaultDir.deletingLastPathComponent()
            .appendingPathComponent("vault-set-aside-\(stamp)", isDirectory: true)
        do {
            try fm.moveItem(at: vaultDir, to: dest)
            try? fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: dest.path)
        } catch {
            self.error = "Could not set the old notebook aside: \(error.localizedDescription)"
            return
        }
        VaultKeyWrap.reset()
        Self.makeProtectedDir(vaultDir)
        error = nil
        refreshState()
    }

    // MARK: Notes

    func saveNote(title: String, markdown: String) async throws -> String {
        guard let v = vault else { throw AppError("Vault is locked") }
        let id = try await offMain { try v.saveNote(title: title, markdown: markdown) }
        protectVaultFiles()
        onNoteSaved?()
        return id
    }

    func listNotes() async throws -> [NoteSummary] {
        guard let v = vault else { return [] }
        return try await offMain { try v.listNotes() }
    }

    func readNote(id: String) async throws -> String {
        guard let v = vault else { throw AppError("Vault is locked") }
        return try await offMain { try v.readNote(id: id) }
    }

    // MARK: Private

    private func refreshState() {
        let exists = (try? vaultURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { $0 > 0 } ?? false
        if !exists { state = .noVault } else { state = VaultKeyWrap.hasKey ? .locked : .keyLost }
    }

    /// Delete a notebook file `create()` just made, with SQLite's side files.
    private func removePartialVault() {
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? fm.removeItem(atPath: vaultURL.path + suffix)
        }
    }

    private func run(_ body: @escaping () async throws -> Void) async {
        busy = true
        error = nil
        defer { busy = false }
        do { try await body() } catch { self.error = describe(error) }
    }

    private static func makeProtectedDir(_ dir: URL) {
        let attrs: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.complete]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: attrs)
        try? FileManager.default.setAttributes(attrs, ofItemAtPath: dir.path)
    }

    /// The vault directory and everything in it gets NSFileProtectionComplete.
    private func protectVaultFiles() {
        let fm = FileManager.default
        let attrs: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.complete]
        try? fm.setAttributes(attrs, ofItemAtPath: vaultDir.path)
        if let items = fm.enumerator(atPath: vaultDir.path) {
            for case let rel as String in items {
                try? fm.setAttributes(attrs, ofItemAtPath: vaultDir.appendingPathComponent(rel).path)
            }
        }
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}

// MARK: - Secure Enclave key wrapping

/// Wraps the vault key with a Secure Enclave P-256 key (ECIES, X9.63 SHA-256 +
/// AES-GCM). Both keychain items are `WhenPasscodeSetThisDeviceOnly`, so iOS
/// deletes them if the passcode is removed and they never sync or back up.
enum VaultKeyWrap {
    enum Failure: Error, LocalizedError {
        case missing
        case secureEnclave(String)
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .missing: "The notebook key is not on this device."
            case .secureEnclave(let m): "Secure Enclave error: \(m)"
            case .keychain(let s): "Keychain error \(s)."
            }
        }
    }

    static let noPasscodeMessage =
        "Set a device passcode in Settings to use the notebook. Its key is protected by Face ID "
        + "and your passcode, and iOS erases that key if the passcode is turned off."

    private static let service = "org.recordless.ios.vault"
    private static let blobAccount = "wrapped-vault-key"
    private static let keyTag = Data("org.recordless.ios.vault.se-key".utf8)
    private static let algorithm = SecKeyAlgorithm.eciesEncryptionCofactorVariableIVX963SHA256AESGCM

    /// Nil if a notebook can be created and unlocked on this device.
    static var unavailableReason: String? {
        var err: NSError?
        if !LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) {
            if let e = err as? LAError, e.code == .passcodeNotSet { return noPasscodeMessage }
            return "Face ID or a device passcode is required to use the notebook."
        }
        #if targetEnvironment(simulator)
        return "The notebook needs the Secure Enclave, which the simulator doesn't have. Use a real iPhone."
        #else
        return nil
        #endif
    }

    /// Both the SE key and the wrapped blob are present (checked without prompting).
    static var hasKey: Bool { privateKeyExists && blobExists }

    fileprivate static func store(key: KeyBox) throws {
        reset()
        var cfErr: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            [.privateKeyUsage, .userPresence], &cfErr) else {
            throw cfErr.map { $0.takeRetainedValue() as Error } ?? Failure.secureEnclave("access control")
        }
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: keyTag,
                kSecAttrAccessControl as String: access,
            ] as [String: Any],
        ]
        guard let privateKey = SecKeyCreateRandomKey(attrs as CFDictionary, &cfErr) else {
            throw cfErr.map { $0.takeRetainedValue() as Error } ?? Failure.secureEnclave("key generation")
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              SecKeyIsAlgorithmSupported(publicKey, .encrypt, algorithm),
              // No-copy CFData over the box's buffer (`key as CFData` would copy).
              let wrapped = key.withCFData({ SecKeyCreateEncryptedData(publicKey, algorithm, $0, &cfErr) }) as Data? else {
            reset()
            throw cfErr.map { $0.takeRetainedValue() as Error } ?? Failure.secureEnclave("encrypt")
        }
        var q = blobQuery()
        q[kSecValueData as String] = wrapped
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else {
            reset()
            throw Failure.keychain(status)
        }
    }

    /// Face ID (passcode fallback) prompt, then decrypt inside the Secure Enclave.
    /// The caller must wipe the returned key once it has been used.
    fileprivate static func unwrap(reason: String) async throws -> KeyBox {
        guard let wrapped = readBlob() else { throw Failure.missing }
        let context = LAContext()
        try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        let ctx = UncheckedSendable(context)
        return try await offMain {
            guard let privateKey = try copyPrivateKey(context: ctx.value) else { throw Failure.missing }
            var cfErr: Unmanaged<CFError>?
            // Kept as CFData (no bridging to Data, which could copy); the box
            // copies it out and zeroes this buffer before it is released.
            guard let decrypted = SecKeyCreateDecryptedData(privateKey, algorithm, wrapped as CFData, &cfErr) else {
                throw cfErr.map { $0.takeRetainedValue() as Error } ?? Failure.secureEnclave("decrypt")
            }
            return KeyBox(wipingSource: decrypted)
        }
    }

    static func reset() {
        SecItemDelete(blobQuery() as CFDictionary)
        SecItemDelete(privateKeyQuery() as CFDictionary)
    }

    // MARK: Keychain

    private static func blobQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: blobAccount]
    }

    private static func privateKeyQuery() -> [String: Any] {
        [kSecClass as String: kSecClassKey,
         kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
         kSecAttrApplicationTag as String: keyTag,
         kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave]
    }

    private static var blobExists: Bool { readBlob() != nil }

    private static var privateKeyExists: Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        var q = privateKeyQuery()
        q[kSecReturnAttributes as String] = true
        q[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(q as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    private static func readBlob() -> Data? {
        var q = blobQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private static func copyPrivateKey(context: LAContext) throws -> SecKey? {
        var q = privateKeyQuery()
        q[kSecReturnRef as String] = true
        q[kSecUseAuthenticationContext as String] = context
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let out, CFGetTypeID(out) == SecKeyGetTypeID() else {
            throw Failure.keychain(status)
        }
        return (out as! SecKey)
    }
}

/// Holds the one Swift copy of the vault key in its own allocation so it can
/// be wiped in place (`memset_s`, not elided). Each constructor zeroes the
/// buffer it copied from. Callers see the bytes only through no-copy views.
/// Copies this file cannot reach (uniffi's lift/lower buffers, Security's
/// internals) are listed in CONFIDENTIAL-ios.md, Limits.
fileprivate final class KeyBox: @unchecked Sendable {
    private let buffer: UnsafeMutableRawBufferPointer

    private init(count: Int) {
        buffer = .allocate(byteCount: max(count, 1), alignment: 16)
        buffer.initializeMemory(as: UInt8.self, repeating: 0)
        self.count = count
    }
    private let count: Int

    /// Takes the key from a `Data` and zeroes the source. In place as long as
    /// `source` is the only reference to its storage (as for the value just
    /// lifted from `generateVaultKey()`); otherwise `resetBytes` would wipe a
    /// copy, so callers must not keep other references.
    convenience init(wipingSource source: inout Data) {
        self.init(count: source.count)
        let dst = buffer
        source.withUnsafeBytes { src in dst.copyMemory(from: src) }
        source.resetBytes(in: 0..<source.count)
    }

    /// Takes the key from the CFData Security returned and zeroes that buffer.
    /// It is a fresh, uniquely owned heap object, so writing through its byte
    /// pointer is the only way to clear it (a mutable copy would be a third copy).
    convenience init(wipingSource source: CFData) {
        let n = CFDataGetLength(source)
        self.init(count: n)
        if n > 0, let src = CFDataGetBytePtr(source) {
            buffer.baseAddress!.copyMemory(from: src, byteCount: n)
            _ = memset_s(UnsafeMutableRawPointer(mutating: src), n, 0, n)
        }
    }

    deinit {
        wipe()
        buffer.deallocate()
    }

    func wipe() { _ = memset_s(buffer.baseAddress, buffer.count, 0, buffer.count) }

    /// A `Data` over the box's buffer, valid only inside `body` (no copy).
    func withData<T>(_ body: (Data) throws -> T) rethrows -> T {
        try body(Data(bytesNoCopy: buffer.baseAddress!, count: count, deallocator: .none))
    }

    /// A CFData over the box's buffer, valid only inside `body` (no copy).
    func withCFData<T>(_ body: (CFData) throws -> T) rethrows -> T {
        let cf = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault,
                                             buffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                             count, kCFAllocatorNull)!
        return try body(cf)
    }
}

/// LAContext isn't Sendable; it is only handed to one background call here.
private struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
