/// Identificatori di oggetto (**OID**) usati da CMS, CAdES, PAdES e X.509.
class Oids {
  static const data = '1.2.840.113549.1.7.1';
  static const signedData = '1.2.840.113549.1.7.2';

  static const sha256 = '2.16.840.1.101.3.4.2.1';
  static const sha384 = '2.16.840.1.101.3.4.2.2';
  static const sha512 = '2.16.840.1.101.3.4.2.3';
  static const rsaEncryption = '1.2.840.113549.1.1.1';
  static const sha256WithRsa = '1.2.840.113549.1.1.11';

  static const contentType = '1.2.840.113549.1.9.3';
  static const messageDigest = '1.2.840.113549.1.9.4';
  static const signingTime = '1.2.840.113549.1.9.5';
  static const signingCertificateV2 = '1.2.840.113549.1.9.16.2.47';
  static const signingCertificate = '1.2.840.113549.1.9.16.2.12';
  static const signatureTimeStampToken = '1.2.840.113549.1.9.16.2.14';

  static const commonName = '2.5.4.3';
  static const surname = '2.5.4.4';
  static const serialNumber = '2.5.4.5';
  static const country = '2.5.4.6';
  static const organization = '2.5.4.10';
  static const givenName = '2.5.4.42';

  static const keyUsage = '2.5.29.15';
  static const basicConstraints = '2.5.29.19';
  static const extKeyUsage = '2.5.29.37';
}
