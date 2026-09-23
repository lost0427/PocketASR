# sherpa-mnn C API snapshot

`include/sherpa-mnn/c-api/c-api.h` is an unmodified snapshot of:

- repository: <https://github.com/alibaba/MNN>
- commit: `d407447ed56c4121a11ccbd266dc184ca1ead0c2` (MNN 3.6.1)
- path: `apps/frameworks/sherpa-mnn/sherpa-mnn/c-api/c-api.h`
- SHA-256 (LF bytes): `5b1e0877880605e797d12cbdfc5d082ae28a704fe28f07959332134b3214470d`

The snapshot and the generated Dart bindings are used only for the narrow
offline SenseVoice API. `scripts/ci/build_native_sherpa_mnn.sh` compares this
file byte-for-byte with the header at the pinned checkout and compiles
`abi_probe.cc` against that checkout before building the Android library.

The upstream MNN project is licensed under Apache License 2.0. Its license is
preserved in `UPSTREAM_LICENSE.txt`. The header identifies Xiaomi Corporation
as its copyright holder.
