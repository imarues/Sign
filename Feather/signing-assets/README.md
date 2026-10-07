# Signing Assets

This directory is bundled with the app and read automatically at launch by `AppDelegate._addDefaultCertificates()`.

Create one subfolder per certificate. Each certificate folder must contain exactly:

- `cert.p12`
- `cert.mobileprovision`
- `cert.txt` — the P12 password as plain text

Example:

```
signing-assets/
└── iKiraPlus/
    ├── cert.p12
    ├── cert.mobileprovision
    └── cert.txt
```

The app imports complete certificate folders automatically and skips incomplete folders.
