"""apk-content-hash.py <apk>...: print "<sha256>\t<path>" per file, the signature segment excluded.

An apk is concatenated gzip members: signature (tar holding one .SIGN.* entry), control (.PKGINFO, which pins the
data member by its sha256 as datahash) and data. Only the signature depends on the signing key, so two builds of
the same inputs signed with different keys hash the same here. A file whose first member is not a signature
(unsigned apk, or not gzip at all) is hashed whole. Stdlib only; run as `python3 -I`.
"""
import hashlib
import sys
import zlib


def content_bytes(data: bytes) -> bytes:
    """data without its leading signature member, or data unchanged when it has none."""
    d = zlib.decompressobj(31)  # 31: gzip header; stops at the end of the first member
    try:
        head = d.decompress(data, 512)
        if not head.startswith(b".SIGN."):
            return data
        d.decompress(d.unconsumed_tail)  # rest of the (small) signature member
    except zlib.error:
        return data
    if not d.eof:
        return data  # truncated first member: not a well-formed apk, compare whole
    return d.unused_data


def main(paths: list[str]) -> None:
    if not paths:
        sys.exit("usage: apk-content-hash.py <apk>...")
    for p in paths:
        with open(p, "rb") as f:
            data = f.read()
        print(hashlib.sha256(content_bytes(data)).hexdigest() + "\t" + p)


if __name__ == "__main__":
    main(sys.argv[1:])
