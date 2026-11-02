# Test fixtures

`fixture-ipad.p12` (password `fixture`) is a throwaway client certificate for
unit tests: CN "Fixture iPad", URI SAN `spiffe://pinos.dev/fort/device/fixture-ipad`,
signed by a one-off "Fort Test Fixture CA (untrusted)" whose key was discarded.
Nothing trusts that CA, so the key inside this file grants access to nothing.
Legacy PKCS#12 encryption (SHA1 + 3DES/RC2), the format iOS can import.
