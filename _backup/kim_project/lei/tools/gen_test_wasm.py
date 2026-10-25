# gen_test_wasm.py —— 手工构造测试 WASM 模块（用于 wasm_sandbox 实装验证；跑完即删）
# 模块1 clue_test.wasm：memory 1页 + clue(8邻求和) + globalCheck(按位与1)
# 模块2 huge_mem.wasm：memory 300页(19.2MB，用于验证 16MB 防线)


def uleb(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def section(sid, payload):
    return bytes([sid]) + uleb(len(payload)) + payload


def vec(items):
    return uleb(len(items)) + b"".join(items)


def name(s):
    b = s.encode()
    return uleb(len(b)) + b


def build(memory_pages, exports, types, type_idx, bodies):
    out = b"\x00asm\x01\x00\x00\x00"
    tlist = []
    for params, results in types:
        tlist.append(b"\x60" + uleb(len(params)) + bytes(params) + uleb(len(results)) + bytes(results))
    out += section(1, vec(tlist))
    out += section(3, vec([uleb(t) for t in type_idx]))
    if memory_pages:
        out += section(5, uleb(1) + b"\x00" + uleb(memory_pages))
    elist = [name(en) + bytes([ek]) + uleb(ei) for en, ek, ei in exports]
    out += section(7, vec(elist))
    blist = []
    for body in bodies:
        b = uleb(0) + body + b"\x0b"
        blist.append(uleb(len(b)) + b)
    out += section(10, vec(blist))
    return out


i32 = 0x7F
OUT = r"E:\Porject\kim project\lei\tools"

# 模块1：clue = 8 参数求和；globalCheck = param & 1
clue_body = b""
for i in range(8):
    clue_body += b"\x20" + uleb(i)
    if i > 0:
        clue_body += b"\x6a"
gc_body = b"\x20\x00\x41\x01\x71"
mod1 = build(
    memory_pages=1,
    exports=[("memory", 2, 0), ("clue", 0, 0), ("globalCheck", 0, 1)],
    types=[([i32] * 8, [i32]), ([i32], [i32])],
    type_idx=[0, 1],
    bodies=[clue_body, gc_body],
)
open(OUT + r"\clue_test.wasm", "wb").write(mod1)

# 模块2：300 页内存（19.2MB > 16MB）
mod2 = build(
    memory_pages=300,
    exports=[("memory", 2, 0)],
    types=[([], [])],
    type_idx=[0],
    bodies=[b""],
)
open(OUT + r"\huge_mem.wasm", "wb").write(mod2)

print("clue_test.wasm", len(mod1), "bytes; huge_mem.wasm", len(mod2), "bytes")
