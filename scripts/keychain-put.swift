import Foundation
import Security
import Darwin
let allowed = ["TaskSecretary.PoC.Bark", "TaskSecretary.PoC.AI.cloud", "TaskSecretary.PoC.AI.ollama", "TaskSecretary.PoC.AI.lmstudio"]
guard CommandLine.arguments.count == 2, allowed.contains(CommandLine.arguments[1]) else {
    print("Usage: swift scripts/keychain-put.swift TaskSecretary.PoC.Bark (or TaskSecretary.PoC.AI.cloud/ollama/lmstudio)"); exit(2)
}
// This PoC CLI uses the file-based keychain, matching security(1) readers.
// A signed product should use Data Protection Keychain with a matching reader.
var defaultKeychain: SecKeychain?
var flags: SecKeychainStatus = 0
if SecKeychainCopyDefault(&defaultKeychain) == errSecSuccess,
   let keychain = defaultKeychain,
   SecKeychainGetStatus(keychain, &flags) == errSecSuccess,
   (flags & kSecUnlockStateStatus) == 0 {
    print("BLOCKED: login keychain locked. Run security unlock-keychain in your local Terminal, then retry.")
    exit(2)
}
guard let raw = getpass("Secret (hidden): "), let value = String(validatingCString: raw), !value.isEmpty else { exit(2) }
let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: CommandLine.arguments[1], kSecAttrAccount as String: "poc"]
let data = Data(value.utf8)
var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
if status == errSecItemNotFound {
    var add = query; add[kSecValueData as String] = data
    status = SecItemAdd(add as CFDictionary, nil)
}
print("Keychain status=\(status)")
if status != errSecSuccess, let message = SecCopyErrorMessageString(status, nil) {
    print(message)
}
exit(status == errSecSuccess ? 0 : 1)
