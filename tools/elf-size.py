#!/usr/bin/env python3
"""解析 ELF 的 section 大小（用于嵌入式 flash/RAM 实测报告）。

用法：python tools/elf-size.py <file.elf> [--csv]
输出：每行 `section,<名字>,<字节>`，最后汇总 text/rodata/data/bss/total_flash/total_ram。
支持 ELF32 / ELF64、小端/大端。
"""
import struct
import sys


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    path = sys.argv[1]
    csv_mode = "--csv" in sys.argv

    with open(path, "rb") as f:
        data = f.read()

    if data[:4] != b"\x7fELF":
        print("not an ELF file", file=sys.stderr)
        return 1
    ei_class = data[4]  # 1=32bit 2=64bit
    ei_data = data[5]   # 1=LE 2=BE
    endian = "<" if ei_data == 1 else ">"

    if ei_class == 1:
        e_shoff, = struct.unpack_from(endian + "I", data, 0x20)
        e_shentsize, e_shnum, e_shstrndx = struct.unpack_from(endian + "HHH", data, 0x2E)
        shdr_fmt = endian + "IIIIIIIIII"   # name,type,flags,addr,offset,size,link,info,align,entsize
    elif ei_class == 2:
        e_shoff, = struct.unpack_from(endian + "Q", data, 0x28)
        e_shentsize, e_shnum, e_shstrndx = struct.unpack_from(endian + "HHH", data, 0x3A)
        shdr_fmt = endian + "IIQQQQIIQQ"
    else:
        print("bad ELF class", file=sys.stderr)
        return 1

    shdrs = []
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        name, stype, flags, addr, offset, size, link, info, align, entsize = struct.unpack_from(shdr_fmt, data, off)
        shdrs.append(dict(name_off=name, type=stype, flags=flags, offset=offset, size=size))

    strtab = shdrs[e_shstrndx]
    strdata = data[strtab["offset"]: strtab["offset"] + strtab["size"]]

    def name_of(o: int) -> str:
        end = strdata.find(b"\x00", o)
        return strdata[o:end].decode("utf-8", "replace")

    SHF_ALLOC = 0x2
    SHT_NOBITS = 8
    total = {"text": 0, "rodata": 0, "data": 0, "bss": 0, "other": 0}
    lines = []
    for s in shdrs:
        if not (s["flags"] & SHF_ALLOC):
            continue
        n = name_of(s["name_off"])
        size = s["size"]
        lines.append((n, size, s["type"] == SHT_NOBITS))
        if n.startswith(".text"):
            total["text"] += size
        elif n.startswith(".rodata") or n.startswith(".srodata"):
            total["rodata"] += size
        elif n.startswith(".bss"):
            total["bss"] += size
        elif n.startswith(".data"):
            total["data"] += size
        else:
            total["other"] += size

    if csv_mode:
        for n, size, _nobits in lines:
            print(f"section,{n},{size}")
        print(f"total,text,{total['text']}")
        print(f"total,rodata,{total['rodata']}")
        print(f"total,data,{total['data']}")
        print(f"total,bss,{total['bss']}")
        print(f"total,other_alloc,{total['other']}")
        print(f"total,flash,{total['text'] + total['rodata'] + total['data'] + total['other']}")
        print(f"total,ram_static,{total['data'] + total['bss'] + total['other']}")
    else:
        for n, size, nobits in lines:
            print(f"{n:24s} {size:8d} {'(ram)' if nobits else ''}")
        print("-" * 40)
        print(f"{'text':24s} {total['text']:8d}")
        print(f"{'rodata':24s} {total['rodata']:8d}")
        print(f"{'data':24s} {total['data']:8d}")
        print(f"{'bss':24s} {total['bss']:8d}")
        print(f"{'other(alloc)':24s} {total['other']:8d}")
        print(f"{'flash 合计':24s} {total['text'] + total['rodata'] + total['data'] + total['other']:8d}")
        print(f"{'RAM 静态合计':24s} {total['data'] + total['bss'] + total['other']:8d}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
