#!/usr/bin/env python3
"""Self-test for verify_apk_native.py with synthetic minimal ELF64 libs.

No cross toolchain needed: hand-built bytes exercise exactly the branches the
release gate depends on — LOAD alignment/congruence, DT_NEEDED closure,
required symbols, and APK STORED+16KB zip placement. Run:
    python3 scripts/ci/test_verify_apk_native.py
"""
import binascii
import os
import struct
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from verify_apk_native import main as verify  # noqa: E402

DT_NULL, DT_NEEDED, DT_STRTAB, DT_SONAME = 0, 1, 5, 14
PT_LOAD, PT_DYNAMIC = 1, 2
SHT_STRTAB, SHT_DYNSYM = 3, 11


def build_lib(align: int, extra_needed=(), exports=("must_have",)) -> bytes:
    """Minimal aarch64 ELF64: one PT_LOAD covering the file with
    vaddr == file offset (congruent for any page), a PT_DYNAMIC, .dynstr,
    and .dynsym/.strtab sections."""
    names = ["libc.so", "soname.so", *extra_needed, *exports]
    strtab, offs = b"\0", {}
    for n in names:
        if n not in offs:
            offs[n] = len(strtab)
            strtab += n.encode() + b"\0"

    syms = b"\0" * 24 + b"".join(
        struct.pack("<IBBHQQ", offs[e], 0x12, 0, 1, 0, 0) for e in exports)

    ph_off, dyn_off = 64, 64 + 2 * 56
    str_off = dyn_off + (2 + 1 + 1 + len(extra_needed)) * 16  # dyn entry count
    sym_off = str_off + len(strtab)
    end = sym_off + len(syms)
    total = end + align  # padding so the mapping stays congruent
    sh_off = total

    dyn = b"".join(struct.pack("<qQ", t, v) for t, v in [
        (DT_STRTAB, str_off), (DT_SONAME, offs["soname.so"]),
        *[(DT_NEEDED, offs[n]) for n in ["libc.so", *extra_needed]],
        (DT_NULL, 0),
    ])
    assert len(dyn) == str_off - dyn_off

    phdr = struct.pack("<IIQQQQQQ", PT_LOAD, 5, 0, 0, 0, total, total, align)
    phdr += struct.pack("<IIQQQQQQ", PT_DYNAMIC, 6, dyn_off, dyn_off, 0,
                        len(dyn), len(dyn), 8)

    def shdr(sh_type, sh_offset, sh_size, sh_link):
        # name, type, flags, addr, offset, size, link, info, align, entsize
        return struct.pack("<IIQQQQIIQQ", 0, sh_type, 0, 0, sh_offset, sh_size,
                           sh_link, 0, 1, 0)

    # 0: null, 1: .dynstr, 2: .dynsym (sh_link -> 1)
    sections = b"\0" * 64 + shdr(SHT_STRTAB, str_off, len(strtab), 0) \
        + shdr(SHT_DYNSYM, sym_off, len(syms), 1)

    ehdr = b"\x7fELF\x02\x01\x01" + b"\0" * 9
    ehdr += struct.pack("<HHIQ", 3, 183, 1, 0)          # type, machine, ver, entry
    ehdr += struct.pack("<QQ", ph_off, sh_off)
    ehdr += struct.pack("<IHHHHHH", 0, 64, 56, 2, 64, 3, 0)

    return (ehdr + phdr + dyn + strtab + syms
            + b"\0" * (total - sym_off - len(syms)) + sections)


def write_apk(path, entries, align=16384):
    """Minimal STORED zip emulating zipalign: the alignment padding lives in
    each LOCAL header's extra field only, while the central directory records
    no extra. Python's `zipfile` writes the same extra to both, which hid a
    bug where the gate read ZipInfo.extra (central) instead of the local
    header and false-failed every real zipaligned APK."""
    out = bytearray()
    central = []
    for name, data in entries:
        nb = name.encode()
        pad = (-(30 + len(nb))) % align
        crc = binascii.crc32(data) & 0xFFFFFFFF
        off = len(out)
        out += struct.pack("<IHHHHHIIIHH", 0x04034B50, 20, 0, 0, 0, 0, crc,
                           len(data), len(data), len(nb), pad)
        out += nb + b"\0" * pad + data
        central.append((nb, off, crc, len(data)))
    cd_off = len(out)
    for nb, off, crc, size in central:
        out += struct.pack("<IHHHHHHIIIHHHHHII", 0x02014B50, 20, 20, 0, 0, 0, 0,
                           crc, size, size, len(nb), 0, 0, 0, 0, 0, off)
        out += nb
    cd_size = len(out) - cd_off
    out += struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, len(central),
                       len(central), cd_size, cd_off, 0)
    with open(path, "wb") as fh:
        fh.write(out)


def run():
    good = build_lib(0x4000)
    bad_align = build_lib(0x1000)
    bad_dep = build_lib(0x4000, extra_needed=["libmystery.so"])

    with tempfile.TemporaryDirectory() as td:
        d = os.path.join(td, "ok")
        os.makedirs(d)
        with open(os.path.join(d, "libgood.so"), "wb") as fh:
            fh.write(good)
        assert verify([d, "--require", "libgood.so",
                       "--require-symbol", "libgood.so:must_have"]) == 0, \
            "aligned lib dir must PASS"
        assert verify([d, "--require-symbol", "libgood.so:absent"]) == 1, \
            "missing export must FAIL"

        apk = os.path.join(td, "app.apk")
        write_apk(apk, [("lib/arm64-v8a/libgood.so", good)])
        assert verify([apk]) == 0, "aligned STORED APK must PASS"

        narrow = os.path.join(td, "narrow.apk")
        write_apk(narrow, [("lib/arm64-v8a/libgood.so", good)], align=4)
        assert verify([narrow]) == 1, \
            "4-byte-but-not-16KB APK offset must FAIL"

        for name, blob, why in [
            ("bad1.apk", bad_align, "4KB-aligned lib must FAIL"),
            ("bad2.apk", bad_dep, "unresolvable DT_NEEDED must FAIL"),
        ]:
            p = os.path.join(td, name)
            write_apk(p, [("lib/arm64-v8a/libx.so", blob)])
            assert verify([p]) == 1, why

        d2 = os.path.join(td, "stale")
        os.makedirs(d2)
        with open(os.path.join(d2, "libggml.so"), "wb") as fh:
            fh.write(good)
        assert verify([d2, "--require", "libcrispasr.so"]) == 1, \
            "missing required lib must FAIL"

    print("test_verify_apk_native: all assertions passed")


if __name__ == "__main__":
    run()
