#!/usr/bin/env python3
"""Fail-closed native-library gate for PocketASR Android APKs.

Checks, for every lib/arm64-v8a/*.so in an APK (or a directory of .so files,
for local wiring tests):

1. ELF LOAD alignment (inside the file): every PT_LOAD has p_align >= 16384
   AND p_offset == p_vaddr (mod 16384)  — Android 16KB-page requirement
   (https://developer.android.com/guide/practices/page-sizes).
2. APK zip placement (container): a STORED .so's data must start at a
   16KB-aligned offset within the APK (what `zipalign -P 16` guarantees), so
   the loader can mmap it in place. Compressed .so entries fail too.
3. DT_NEEDED closure: every library a .so needs is either bundled in the same
   APK lib dir or is a known Android *system* library. Anything else (e.g. a
   stray libomp.so) fails the build — that is the point.
4. Required libraries present: --require NAME (repeatable).
5. Required exported symbols: --require-symbol NAME.so:sym (repeatable).
   Guards against -fvisibility=hidden swallowing the FFI ABI.

Exit 0 = all good; exit 1 = do not ship. stdlib only (runs anywhere CI does).
"""
from __future__ import annotations

import argparse
import os
import struct
import sys
import zipfile

PAGE = 16384
PT_LOAD, PT_DYNAMIC = 1, 2
DT_NULL, DT_NEEDED, DT_STRTAB, DT_SONAME = 0, 1, 5, 14
SHN_UNDEF, SHT_PROGBITS, SHT_DYNSYM, SHT_STRTAB = 0, 1, 11, 3
STB_GLOBAL, STB_WEAK = 1, 2

# Public NDK system libraries resolvable at runtime without bundling
# (subset reachable from ggml/crisp/miniaudio code paths + bionic basics).
SYSTEM_LIBS = {
    "ld-android.so", "libdl.so", "libc.so", "libm.so", "liblog.so",
    "libandroid.so", "libaaudio.so", "libamidi.so", "libbinder_ndk.so",
    "libcutils.so", "libcamera2ndk.so", "libEGL.so", "libGLESv1_CM.so",
    "libGLESv2.so", "libGLESv3.so", "libjnigraphics.so",
    "libmediandk.so", "libnativewindow.so", "libneuralnetworks.so",
    "libOpenMAXAL.so", "libOpenSLES.so", "libsync.so", "libvulkan.so",
    "libWebGL.so",
}
# NOT system: libc++_shared.so and libomp.so must be bundled if a .so needs
# them (the NDK ships them; AGP does NOT add them for plain jniLibs inputs).


def _cstr(data: bytes, off: int) -> str:
    end = data.index(b"\0", off)
    return data[off:end].decode("utf-8", "replace")


def _vaddr_to_off(load_segs, vaddr: int):
    for p_off, p_vaddr, p_filesz in load_segs:
        if p_filesz and p_vaddr <= vaddr < p_vaddr + p_filesz:
            return p_off + (vaddr - p_vaddr)
    return None


def parse_elf(data: bytes, name: str):
    """Return (p_aligns, load_segs, needed, soname, exported-set) for ELF64 LE."""
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        raise ValueError(f"{name}: not a little-endian ELF64 binary")
    if struct.unpack_from("<H", data, 18)[0] != 183:  # EM_AARCH64
        raise ValueError(f"{name}: not an aarch64 library (abiFilters=arm64-v8a)")

    e_phoff = struct.unpack_from("<Q", data, 0x20)[0]
    e_phentsize, e_phnum = struct.unpack_from("<HH", data, 0x36)
    aligns, load_segs, dyn_off = [], [], None
    for i in range(e_phnum):
        base = e_phoff + i * e_phentsize
        p_type, _, p_offset, p_vaddr, _, p_filesz, _, p_align = struct.unpack_from(
            "<IIQQQQQQ", data, base)
        if p_type == PT_LOAD:
            load_segs.append((p_offset, p_vaddr, p_filesz))
            aligns.append(p_align)
        elif p_type == PT_DYNAMIC:
            dyn_off = p_offset

    entries, strtab_file = [], None
    if dyn_off is not None:
        for off in range(dyn_off, dyn_off + len(data), 16):
            d_tag, d_val = struct.unpack_from("<qQ", data, off)
            if d_tag == DT_NULL:
                break
            entries.append((d_tag, d_val))
        for d_tag, d_val in entries:
            if d_tag == DT_STRTAB:
                strtab_file = _vaddr_to_off(load_segs, d_val)
                break

    needed, soname = [], ""
    if strtab_file is not None:
        for d_tag, d_val in entries:
            if d_tag == DT_NEEDED:
                needed.append(_cstr(data, strtab_file + d_val))
            elif d_tag == DT_SONAME:
                soname = _cstr(data, strtab_file + d_val)

    exports = set()
    e_shoff = struct.unpack_from("<Q", data, 0x28)[0]
    e_shentsize, e_shnum = struct.unpack_from("<HH", data, 0x3A)
    sections = []
    for i in range(e_shnum):
        base = e_shoff + i * e_shentsize
        sh_type = struct.unpack_from("<I", data, base + 4)[0]
        sh_offset = struct.unpack_from("<Q", data, base + 0x18)[0]
        sh_size = struct.unpack_from("<Q", data, base + 0x20)[0]
        sh_link = struct.unpack_from("<I", data, base + 40)[0]
        sections.append((sh_type, sh_offset, sh_size, sh_link))
    for sh_type, sh_offset, sh_size, sh_link in sections:
        if sh_type != SHT_DYNSYM or sh_size == 0:
            continue
        sym_strtab = sections[sh_link][1] if sh_link < len(sections) else None
        if sym_strtab is None:
            break
        for i in range(0, sh_size, 24):
            st_name, st_info, _, st_shndx = struct.unpack_from("<IBBH", data,
                                                               sh_offset + i)
            if st_shndx != SHN_UNDEF and (st_info >> 4) in (STB_GLOBAL, STB_WEAK):
                exports.add(_cstr(data, sym_strtab + st_name))
        break

    return aligns, load_segs, needed, soname, exports


def check_lib(name: str, data: bytes):
    """Return (problems, needed, exports) for one library."""
    try:
        aligns, load_segs, needed, soname, exports = parse_elf(data, name)
    except (ValueError, struct.error) as exc:
        return [str(exc)], [], set()
    problems = []
    for i, align in enumerate(aligns):
        if align < PAGE:
            problems.append(
                f"PT_LOAD[{i}] p_align=0x{align:x} < 0x4000 (not 16KB-aligned)")
    for p_off, p_vaddr, _ in load_segs:
        if (p_off - p_vaddr) % PAGE:
            problems.append(
                f"PT_LOAD p_offset=0x{p_off:x} !== p_vaddr=0x{p_vaddr:x} mod 16KB")
    return problems, needed, exports


def _local_data_offset(raw, zi) -> int:
    """File-data offset from the LOCAL header, or -1 if it is malformed.

    zipalign's alignment padding lives in the local header's extra field only;
    ZipInfo.extra comes from the central directory and is empty in a real
    zipaligned APK, so using it under-reports the offset and false-fails."""
    raw.seek(zi.header_offset)
    fixed = raw.read(30)
    if len(fixed) < 30 or struct.unpack_from("<I", fixed, 0)[0] != 0x04034B50:
        return -1
    name_len, extra_len = struct.unpack_from("<HH", fixed, 26)
    return zi.header_offset + 30 + name_len + extra_len


def collect_targets(target: str):
    """Return ({basename: bytes}, extra_ok) for an APK or a directory."""
    if os.path.isdir(target):
        out = {}
        for fn in sorted(os.listdir(target)):
            if fn.endswith(".so"):
                with open(os.path.join(target, fn), "rb") as fh:
                    out[fn] = fh.read()
        return out, True
    out, ok = {}, True
    with open(target, "rb") as raw, zipfile.ZipFile(target) as zf:
        for zi in zf.infolist():
            if not (zi.filename.startswith("lib/arm64-v8a/")
                    and zi.filename.endswith(".so")):
                continue
            base = os.path.basename(zi.filename)
            if zi.compress_type != zipfile.ZIP_STORED:
                print(f"FAIL {base}: compressed in APK; native libs must be "
                      "STORED (packaging.jniLibs.useLegacyPackaging=false)")
                ok = False
            data_off = _local_data_offset(raw, zi)
            if data_off < 0:
                print(f"FAIL {base}: malformed local file header")
                ok = False
            elif data_off % PAGE:
                print(f"FAIL {base}: data starts at {data_off}, not 16KB "
                      "aligned in the APK (zipalign -P 16)")
                ok = False
            out[base] = zf.read(zi)
    return out, ok


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        description="16KB alignment + DT_NEEDED closure gate for an Android APK")
    ap.add_argument("target", help="APK path or directory of .so files")
    ap.add_argument("--require", action="append", default=[],
                    metavar="NAME.so", help="library that must be present")
    ap.add_argument("--require-symbol", action="append", default=[],
                    metavar="NAME.so:sym", help="exported symbol that must exist")
    ap.add_argument("--report", action="store_true",
                    help="print SONAME/DT_NEEDED per library")
    args = ap.parse_args(argv)

    libs, ok = collect_targets(args.target)
    if not libs:
        print("FAIL: no lib/arm64-v8a/*.so found")
        return 1

    all_exports = {}
    for name, data in sorted(libs.items()):
        problems, needed, exports = check_lib(name, data)
        all_exports[name] = exports
        for dep in needed:
            if dep not in libs and dep not in SYSTEM_LIBS:
                problems.append(
                    f"DT_NEEDED '{dep}' neither bundled nor a system library")
        if args.report:
            print(f"{name}: needed={needed}")
        if problems:
            ok = False
            for p in problems:
                print(f"FAIL {name}: {p}")
        else:
            print(f"ok   {name} ({len(needed)} DT_NEEDED, {len(exports)} exports)")

    for req in args.require:
        if req not in libs:
            print(f"FAIL: required library missing: {req}")
            ok = False
    for spec in args.require_symbol:
        libname, _, sym = spec.partition(":")
        if sym not in all_exports.get(libname, set()):
            print(f"FAIL: {libname} does not export {sym}")
            ok = False

    print("verify_apk_native: " + ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
