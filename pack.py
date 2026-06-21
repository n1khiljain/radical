import struct
import numpy as np

ORDER = ["conv1_w", "conv1_b", "conv2_w", "conv2_b", "fc1_w", "fc1_b", "fc2_w", "fc2_b"]


def write_bin(arrays, path="weights.bin"):
    offsets = {}
    with open(path, "wb") as f:
        for name in ORDER:
            arr = arrays[name].flatten()
            n_bytes = arr.nbytes
            offset = f.tell()
            f.write(struct.pack("<I", n_bytes))
            f.write(arr.tobytes())
            offsets[name] = (offset, n_bytes)
            print(f"{name}: offset={offset}, length={n_bytes} bytes")
    return offsets


def hex_dump(path, n=32):
    with open(path, "rb") as f:
        data = f.read(n)
    for i in range(0, len(data), 16):
        chunk = data[i:i+16]
        hex_part = " ".join(f"{b:02x}" for b in chunk)
        asc_part = "".join(chr(b) if 32 <= b < 127 else "." for b in chunk)
        print(f"{i:08x}: {hex_part:<47}  {asc_part}")


def verify(arrays, path="weights.bin"):
    ok = True
    with open(path, "rb") as f:
        for name in ORDER:
            n_bytes = struct.unpack("<I", f.read(4))[0]
            raw = np.frombuffer(f.read(n_bytes), dtype=np.int8)
            expected = arrays[name].flatten()
            if not np.array_equal(raw, expected):
                print(f"VERIFY FAIL: {name} mismatch")
                ok = False
    print("VERIFY OK" if ok else "VERIFY FAIL: see details above")


def main():
    arrays = dict(np.load("model_int8.npz"))

    write_bin(arrays)

    size = sum(4 + arrays[n].nbytes for n in ORDER)
    print(f"\nTotal file size: {size} bytes")

    print("\nFirst 32 bytes (xxd):")
    hex_dump("weights.bin")

    print("\nVerifying...")
    verify(arrays)


if __name__ == "__main__":
    main()
