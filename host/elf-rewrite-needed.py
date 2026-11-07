#!/usr/bin/env python3
"""Rewrite DT_NEEDED strings inside an ELF64 file, in place.

patchelf (0.18) relocates PT_INTERP and .dynsym/.dynstr to the end of large
executables when it has to grow the dynamic string table. The Android kernel
then rejects the result with EINVAL on execve, because the relocated segments
no longer satisfy the loader's layout assumptions.

Every rename this project needs is *shorter* than the original
(libglib-2.0.so.0 -> libglib-2.0.so, libz.so.1 -> libz.so, ...), so the new
name fits in the existing .dynstr slot. Overwriting it and NUL-padding the
remainder changes no offsets, no section sizes and no program headers.

Usage:
    elf-rewrite-needed.py FILE OLD=NEW [OLD=NEW ...]
    elf-rewrite-needed.py --list FILE
"""

from __future__ import annotations

import struct
import sys

SHT_DYNAMIC = 6
DT_NULL = 0
DT_NEEDED = 1
DT_SONAME = 14


class ElfError(Exception):
    pass


class Elf64:
    def __init__(self, path: str) -> None:
        self.path = path
        with open(path, "rb") as handle:
            self.data = bytearray(handle.read())

        if self.data[:4] != b"\x7fELF":
            raise ElfError(f"{path}: not an ELF file")
        if self.data[4] != 2 or self.data[5] != 1:
            raise ElfError(f"{path}: expected ELF64 little-endian")

        (self.e_shoff,) = struct.unpack_from("<Q", self.data, 0x28)
        (self.e_shentsize, self.e_shnum, self.e_shstrndx) = struct.unpack_from(
            "<HHH", self.data, 0x3A
        )

        self.sections = []
        for index in range(self.e_shnum):
            base = self.e_shoff + index * self.e_shentsize
            sh_name, sh_type, _flags, _addr, sh_offset, sh_size, sh_link, _info, \
                _align, sh_entsize = struct.unpack_from("<IIQQQQIIQQ", self.data, base)
            self.sections.append(
                {
                    "index": index,
                    "name_off": sh_name,
                    "type": sh_type,
                    "offset": sh_offset,
                    "size": sh_size,
                    "link": sh_link,
                    "entsize": sh_entsize,
                }
            )

    def cstr(self, base: int, limit: int | None = None) -> str:
        end = self.data.find(b"\x00", base)
        if end < 0 or (limit is not None and end >= limit):
            raise ElfError(f"{self.path}: unterminated string at {base:#x}")
        return self.data[base:end].decode("utf-8", "replace")

    def dynamic(self):
        section = next((s for s in self.sections if s["type"] == SHT_DYNAMIC), None)
        if section is None:
            raise ElfError(f"{self.path}: no .dynamic section")
        dynstr = self.sections[section["link"]]
        stride = section["entsize"] or 16
        entries = []
        base = section["offset"]
        for pos in range(0, section["size"], stride):
            tag, value = struct.unpack_from("<qQ", self.data, base + pos)
            if tag == DT_NULL:
                break
            entries.append((base + pos, tag, value))
        return entries, dynstr

    def names(self):
        entries, dynstr = self.dynamic()
        needed = [
            (slot, self.cstr(dynstr["offset"] + value))
            for slot, tag, value in entries
            if tag == DT_NEEDED
        ]
        soname = [
            self.cstr(dynstr["offset"] + value)
            for _, tag, value in entries
            if tag == DT_SONAME
        ]
        return needed, soname

    def rewrite(self, rename: dict[str, str]) -> list[tuple[str, str]]:
        entries, dynstr = self.dynamic()
        dynstr_base = dynstr["offset"]
        dynstr_end = dynstr_base + dynstr["size"]
        changed = []

        for slot, tag, value in entries:
            if tag not in (DT_NEEDED, DT_SONAME):
                continue
            start = dynstr_base + value
            old = self.cstr(start, dynstr_end)
            new = rename.get(old)
            if new is None or new == old:
                continue
            encoded_old = old.encode()
            encoded_new = new.encode()
            if len(encoded_new) > len(encoded_old):
                raise ElfError(
                    f"{self.path}: cannot grow {old!r} -> {new!r} in place "
                    f"({len(encoded_new)} > {len(encoded_old)} bytes)"
                )
            self.data[start:start + len(encoded_old)] = encoded_new + b"\x00" * (
                len(encoded_old) - len(encoded_new)
            )
            changed.append((old, new))

        return changed

    def save(self) -> None:
        with open(self.path, "wb") as handle:
            handle.write(self.data)


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    if argv[1] == "--list":
        for path in argv[2:]:
            elf = Elf64(path)
            needed, soname = elf.names()
            print(f"{path}")
            print(f"  SONAME: {', '.join(soname) or '-'}")
            for _, name in needed:
                print(f"  NEEDED: {name}")
        return 0

    path = argv[1]
    rename: dict[str, str] = {}
    for item in argv[2:]:
        if "=" not in item:
            print(f"bad assignment: {item}", file=sys.stderr)
            return 2
        old, new = item.split("=", 1)
        rename[old] = new

    elf = Elf64(path)
    changed = elf.rewrite(rename)
    elf.save()
    for old, new in changed:
        print(f"  {path}: {old} -> {new}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv))
    except ElfError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
