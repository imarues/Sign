# Bundled signing assets

BatSign/Feather already imports bundled signing certificates at launch from this directory.

Create one subfolder per certificate, for example:

```
Feather/signing-assets/iKiraPlus/
  cert.p12
  cert.mobileprovision
  cert.txt
```

- `cert.p12` — PKCS#12 signing identity.
- `cert.mobileprovision` — matching provisioning profile.
- `cert.txt` — the PKCS#12 password as plain text (may be empty if the identity has no password).

At launch, `FeatherApp.swift` calls `_addDefaultCertificates()`, which reads these three files and passes them to `FR.handleCertificateFiles(...)` as a default certificate.

Security note: do not commit production private signing identities to a public repository. Prefer a private repository or inject them only in a trusted build pipeline.
