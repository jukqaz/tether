import Foundation
import CryptoKit
// Reads the key from a file; never prints it or accepts its value on the command line.
let path = CommandLine.arguments[1]
let raw = try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
guard let bytes = Data(base64Encoded: raw) else { exit(1) }
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: bytes)
let expected = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
guard key.publicKey.rawRepresentation.base64EncodedString() == expected else {
    fputs("Signing key does not match the public key embedded in Tether.\n", stderr); exit(1)
}
