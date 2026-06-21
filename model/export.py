import binascii
import struct
import numpy as np

ORDER = ["conv1_w", "conv1_b", "conv2_w", "conv2_b", "fc1_w", "fc1_b", "fc2_w", "fc2_b"]


def write_weights(arrays, path="weights.bin"):
    with open(path, "wb") as f:
        for name in ORDER:
            flat = arrays[name].flatten(order="C").astype(np.int8)
            n = flat.nbytes
            offset = f.tell()
            f.write(struct.pack("<I", n))
            f.write(flat.tobytes())
            print(f"{name}: offset=0x{offset:04x}, header_value={n}, data_bytes={n}")


def hex_dump(path, n=32):
    with open(path, "rb") as f:
        data = f.read(n)
    print(binascii.hexlify(data, " ", 1).decode().upper())


def verify(arrays, path="weights.bin"):
    with open(path, "rb") as f:
        for name in ORDER:
            n = struct.unpack("<I", f.read(4))[0]
            got = np.frombuffer(f.read(n), dtype=np.int8)
            want = arrays[name].flatten(order="C")
            if not np.array_equal(got, want):
                print(f"VERIFY FAIL: {name} — got {got[:4]} want {want[:4]}")
                return
    print("VERIFY OK")


def main():
    arrays = dict(np.load("model_int8.npz"))

    write_weights(arrays)
    total = sum(4 + arrays[n].nbytes for n in ORDER)
    print(f"\nTotal file size: {total} bytes")

    print("\nFirst 32 bytes:")
    hex_dump("weights.bin")

    print()
    verify(arrays)


if __name__ == "__main__":
    main()
