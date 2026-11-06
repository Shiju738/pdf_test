/// The few pieces of DER needed to send an RSA public key to the server.
library;

import 'dart:typed_data';

List<int> _length(int length) {
  if (length < 0x80) return [length];
  final bytes = <int>[];
  for (var rest = length; rest > 0; rest >>= 8) {
    bytes.insert(0, rest & 0xff);
  }
  return [0x80 | bytes.length, ...bytes];
}

Uint8List _tlv(int tag, List<int> value) =>
    Uint8List.fromList([tag, ..._length(value.length), ...value]);

/// The big-endian bytes of a number that is zero or more, without a sign byte.
List<int> unsignedBytes(BigInt value) {
  final hex = value.toRadixString(16);
  final padded = hex.length.isOdd ? '0$hex' : hex;
  return [
    for (var i = 0; i < padded.length; i += 2)
      int.parse(padded.substring(i, i + 2), radix: 16),
  ];
}

/// INTEGER, for a number that is zero or more.
Uint8List derInteger(BigInt value) {
  final bytes = unsignedBytes(value);
  // A leading zero keeps a number with its top bit set from reading as negative.
  return _tlv(0x02, bytes[0] & 0x80 != 0 ? [0, ...bytes] : bytes);
}

Uint8List derSequence(List<Uint8List> items) =>
    _tlv(0x30, [for (final item in items) ...item]);

Uint8List derBitString(Uint8List bytes) => _tlv(0x03, [0, ...bytes]);

/// PKCS#1 `RSAPublicKey`: SEQUENCE { modulus, publicExponent }.
Uint8List rsaPublicKeyPkcs1(BigInt modulus, BigInt publicExponent) =>
    derSequence([derInteger(modulus), derInteger(publicExponent)]);

// AlgorithmIdentifier { rsaEncryption (1.2.840.113549.1.1.1), NULL }.
const _rsaEncryption = [
  0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, //
  0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00,
];

/// `SubjectPublicKeyInfo` of an RSA key: the layout Android and most tools
/// use. The server takes this and PKCS#1.
Uint8List rsaPublicKeySpki(BigInt modulus, BigInt publicExponent) => derSequence([
  Uint8List.fromList(_rsaEncryption),
  derBitString(rsaPublicKeyPkcs1(modulus, publicExponent)),
]);
