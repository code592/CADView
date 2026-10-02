# Third-party notices

The authoritative dependency versions are `pubspec.lock` and
`rust/Cargo.lock`. Release automation must generate a CycloneDX SBOM and retain
each dependency's license text. The main directly used components are:

The `globalStore` build, but not the Apache-2.0 `community` build, links the
official Google Mobile Ads SDK and Google User Messaging Platform SDK under
Google's applicable SDK terms. They are not relicensed under Apache-2.0 and are
not dependencies of the CAD core. Current native versions are Android Google
Mobile Ads 25.4.0 (including UMP 4.0.0) and iOS Google Mobile Ads 13.9.0 with
Google User Messaging Platform 3.1.0.

| Component | Purpose | License |
|---|---|---|
| Flutter | Android/iOS UI framework | BSD-3-Clause |
| flutter_rust_bridge / Cargokit | Dart-Rust FFI build bridge | MIT |
| acadrust 0.4.1 | DWG R13-R2018+ Beta reader | MPL-2.0 |
| pdfrx_engine / pdfium_flutter / pdfium_dart | PDF API and mobile deployment | MIT |
| PDFium chromium/7811 (build 20260502-190206) | Offline PDF rendering | BSD-3-Clause and bundled third-party terms |
| dxf 0.6.1 (local text-decoding patch) | DXF parser | MIT |
| gltf | glTF/GLB parser | MIT OR Apache-2.0 |
| tobj | OBJ parser | MIT |
| stl_io | STL parser | MIT |
| roxmltree | SVG/3MF XML | MIT OR Apache-2.0 |
| zip | 3MF container | MIT |
| rusqlite / SQLite | Local annotation database | MIT / public domain |
| rstar | 2D spatial index | MIT OR Apache-2.0 |
| BLAKE3 | Source fingerprint | CC0-1.0 OR Apache-2.0 |
| ciborium | Versioned CBOR scene cache | Apache-2.0 |
| Noto Sans CJK SC Regular | Offline fallback for missing CAD SHX/TTF glyphs | SIL Open Font License 1.1 |
| Noto Sans and script-specific Regular fonts listed below | Offline multilingual UI, CAD labels and annotations | SIL Open Font License 1.1 |

Planned, not currently linked:

- Open CASCADE is LGPL-2.1 with its exception. A store build that links it must
  publish the exact version, patches, build scripts and relinking materials.
- Assimp requires a fresh version-specific license review before its adapter
  can replace the current first-party mesh readers.

The PDFium binary version and SHA-256 are pinned by `pdfium_flutter`'s Podspec
and Dart native-assets hook. PDFium's BSD notice is retained in
`third_party_licenses/PDFium-LICENSE.txt`; its upstream root license and
third-party terms must be included in every binary distribution and generated
SBOM.

acadrust 0.4.1 is retained in `rust/vendor/acadrust`, including its full
MPL-2.0 license. The local patch preserves MTEXT's complete WCS direction and
corrects rotated MINSERT grid spacing; the changed upstream files remain
MPL-2.0. `CADVIEW_PATCHES.md` records the original crate checksum and modified
files. Source distributions and release source archives must retain this
directory and notice; the surrounding CADView code remains Apache-2.0.

GPLv3 LibreDWG is intentionally excluded.

The MIT-licensed `dxf` 0.6.1 source and binary-text decoding patch are retained in
`rust/vendor/dxf`, with its original `LICENSE.txt` and local change description
in `CADVIEW_PATCHES.md`. The application retains Apache-2.0; the vendored library
and its local modifications retain MIT.

Noto Sans CJK SC Regular is bundled unmodified from the official
`notofonts/noto-cjk` repository. Its license is retained in
`third_party_licenses/NotoSansCJK-OFL-1.1.txt`; the font SHA-256 is
`2c76254f6fc379fddfce0a7e84fb5385bb135d3e399294f6eeb6680d0365b74b`.
Proprietary Autodesk/AutoCAD SHX fonts (including `ebgen.shx`, `hztxt.shx`,
`simplex.shx` and `romans.shx`) are not bundled.

The additional unmodified Regular TTF fonts come from
[`notofonts/noto-fonts`, commit ffebf8c1ee449e544955a7e813c54f9b73848eac](https://github.com/notofonts/noto-fonts/tree/ffebf8c1ee449e544955a7e813c54f9b73848eac/hinted/ttf).
Their shared upstream license is retained in
`third_party_licenses/NotoFonts-OFL-1.1.txt`. These SHA-256 values pin the exact
bundled binaries:

| Font file | SHA-256 |
|---|---|
| NotoSans-Regular.ttf | b85c38ecea8a7cfb39c24e395a4007474fa5a4fc864f6ee33309eb4948d232d5 |
| NotoSansArabic-Regular.ttf | ceea25b464a656dc3b26849bab9356740401af62aedf1bfa8b7f0d9b75925b1b |
| NotoSansHebrew-Regular.ttf | a7fa16fffb27bedb060a0866267c29e9859aeb9c21cc33f5b3aaf6eb062eca85 |
| NotoSansThai-Regular.ttf | 404ddfb5ed0aaa6b6ec8a85700d682978992062d67da93903967b56cbd9a4acc |
| NotoSansDevanagari-Regular.ttf | 385e78e6359a9d88a0f243d53b1209d7548361ba2194e2b9ec779bcaa7e8949d |
| NotoSansSymbols-Regular.ttf | 8f02f31959bbdf6061547a188248e13f84dc5fdd940326ec494675f453f072bb |
| NotoSansSymbols2-Regular.ttf | 630846d528dbe4c4981370a4d0a9475a1fd1491a129bb411f8e157cdb5de13c6 |
| NotoSansBengali-Regular.ttf | 6300c5370cd688b0641343de4c786de6d412bb6c578d129dae75e93a0322dcab |
| NotoSansGujarati-Regular.ttf | 8d5c22d7b729ef2839e6d1fe2cde77b2d083907be3659bca63676baa76e01fd6 |
| NotoSansGurmukhi-Regular.ttf | bbde4d85fdfb998eff6921cb2c7a9a7924a1c95560a6aa9a06172530e4f596da |
| NotoSansTamil-Regular.ttf | 6532db33b8b264abe3a098a40619feb489b5ddf5ab1d2b46e72b51eeb548001b |
| NotoSansTelugu-Regular.ttf | 2c05072e8018a9be1cb0582953d9edf9a0cf129cdfb74e611de763b09c411f7f |
| NotoSansKannada-Regular.ttf | 5c804033c57f2c2844b1cd425f45b9a78d81d2f71bf358351b24258ebe168aea |
| NotoSansMalayalam-Regular.ttf | 42eb462ff13e820ebbeaaec4e7b426bd1de145d02cef8b634f5a3efd376b513c |
| NotoSansSinhala-Regular.ttf | a966549310b2d3046ba25bbeef11985428ff9356fa656fd6118bc90fb82df031 |
| NotoSansLao-Regular.ttf | 4a64d40850990992913d4be44b2e87a93d52f76882c1f0c0755edcb12ec57aa2 |
| NotoSansKhmer-Regular.ttf | 5c1ec068352f1e1fe8e7a3218230360d054e104d377ef40c0423b17c34c3c259 |
| NotoSansMyanmar-Regular.ttf | 9dd2bc76a822a974efce803a4b07302d14d01d5c1fa9e33a258d15a9cb513a7d |
| NotoSansArmenian-Regular.ttf | c3332abfe298018517d7f5b687a9c0f5c92f163ea9258f23934eaa7a9378f40e |
| NotoSansGeorgian-Regular.ttf | b36ab61cbdd820ffd32f957f704f5bf0c53655e820b7a64001091058919a11a6 |
| NotoSansEthiopic-Regular.ttf | e3a81ca66eb6d6b1a50a287c1dba18195541f69e0986f8b49a42658aa592ff0d |
| NotoSerifTibetan-Regular.ttf | 3dd3876c670008cef5e29a79392fc8874d9bb9e349fc54755b2861c050c0fd7c |
