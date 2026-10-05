#!/usr/bin/env python3
# make_hostiles.py — écrit à la main des modules wasm hostiles que zig ne peut
# pas émettre : table démesurée (min=1M) et sortie géante déjà couverte par
# hostile_mem.wasm.
import struct, os

def varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F; n >>= 7
        if n: out.append(b | 0x80)
        else:
            out.append(b); break
    return bytes(out)

def section(sec_id, payload):
    return bytes([sec_id]) + varint(len(payload)) + payload

# Module : mémoire 1 page, table funcref min=1_000_000 (limite ADR : 65 536),
# exports vh_alloc/vh_call triviaux.
def huge_table():
    m = b"\x00asm\x01\x00\x00\x00"
    # type section : (i32,i32) -> i64 et (i32)->i32  (ABI vh_call / vh_alloc)
    types = section(1, varint(2) +
        b"\x60\x02\x7f\x7f\x01\x7e" +   # (i32,i32) -> i64
        b"\x60\x01\x7f\x01\x7f")         # (i32) -> i32
    funcs = section(3, varint(2) + varint(1) + varint(0))
    table = section(4, varint(1) + b"\x70\x00" + varint(1_000_000))
    mem   = section(5, varint(1) + b"\x01" + varint(1) + varint(1024))
    exp   = section(7, varint(2) +
        varint(8) + b"vh_alloc" + b"\x00" + varint(0) +
        varint(7) + b"vh_call"  + b"\x00" + varint(1))
    code  = section(10, varint(2) +
        varint(4) + b"\x00\x41\x00\x0b" +          # i32.const 0; end
        varint(4) + b"\x00\x42\x00\x0b")           # i64.const 0; end
    return m + types + funcs + table + mem + exp + code

# Module : memory min+max = 1024 pages (64 Mio exactement) — la limite
# pile doit PASSER (test seuil ; >1024 serait MemoryLimit).
def edge_mem():
    m = b"\x00asm\x01\x00\x00\x00"
    types = section(1, varint(2) + b"\x60\x02\x7f\x7f\x01\x7e" + b"\x60\x01\x7f\x01\x7f")
    funcs = section(3, varint(2) + varint(1) + varint(0))
    mem   = section(5, varint(1) + b"\x01" + varint(1024) + varint(1024))
    exp   = section(7, varint(2) +
        varint(8) + b"vh_alloc" + b"\x00" + varint(0) +
        varint(7) + b"vh_call"  + b"\x00" + varint(1))
    code  = section(10, varint(2) +
        varint(4) + b"\x00\x41\x00\x0b" +
        varint(4) + b"\x00\x42\x00\x0b")
    return m + types + funcs + mem + exp + code

os.makedirs("wasm", exist_ok=True)
open("wasm/hostile_table.wasm", "wb").write(huge_table())
open("wasm/edge_mem64.wasm", "wb").write(edge_mem())
for f in ["hostile_table.wasm", "edge_mem64.wasm"]:
    print(f, os.path.getsize("wasm/" + f), "octets")
