# ============================================================
#  raw_to_jpg.py - render a camera RAW file (Sony ARW, DNG, CR2,
#  NEF, ...) to a full-size JPG that photo apps and clouds can show.
#
#  Usage:  python raw_to_jpg.py <raw file> <output .jpg> [fallback date]
#          fallback date is "yyyy:MM:dd HH:mm:ss", used only when the
#          RAW file carries no capture date of its own.
#
#  Called by the import engine for RAW-only shots. Camera white
#  balance + LibRaw's auto brightness (closest match to the camera's
#  own JPG rendering). Orientation is baked into the pixels, so the
#  JPG's Orientation tag is "normal". Capture date, camera model and
#  exposure settings are copied into the JPG's EXIF so photo
#  timelines file it under the real capture time.
#  Needs:  pip install rawpy   (Pillow is already present)
#  Exit code 0 = JPG written, 1 = failed (nothing written).
# ============================================================
import os
import struct
import sys

import rawpy
from PIL import Image
from PIL.TiffImagePlugin import IFDRational

TYPE_SIZES = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 7: 1, 9: 4, 10: 8}
IFD0_COPY = (0x010F, 0x0110, 0x0132)                      # Make, Model, DateTime
EXIF_COPY = (0x9003, 0x9004, 0x8827, 0x829A, 0x829D,      # DateTimeOriginal, Digitized, ISO, Exposure, FNumber
             0x920A, 0x9209, 0x8822, 0x9204, 0xA405)      # FocalLength, Flash, ExposureProgram, ExpBias, Focal35mm


def read_tiff_tags(path):
    """Walk the RAW's TIFF header: IFD0 and its Exif sub-IFD. Returns two dicts."""
    with open(path, "rb") as f:
        data = f.read(8 * 1024 * 1024)
    if data[:2] not in (b"II", b"MM"):
        return {}, {}
    bo = "<" if data[:2] == b"II" else ">"

    def u16(o): return struct.unpack(bo + "H", data[o:o + 2])[0]
    def u32(o): return struct.unpack(bo + "I", data[o:o + 4])[0]

    def read_ifd(off):
        out = {}
        try:
            n = u16(off)
            for i in range(n):
                e = off + 2 + i * 12
                tag, typ, cnt = u16(e), u16(e + 2), u32(e + 4)
                size = TYPE_SIZES.get(typ, 1) * cnt
                vo = e + 8 if size <= 4 else u32(e + 8)
                if vo + size > len(data):
                    continue
                if typ == 2:
                    out[tag] = data[vo:vo + cnt].split(b"\x00")[0].decode("ascii", "replace").strip()
                elif typ == 3:
                    out[tag] = u16(vo)
                elif typ == 4:
                    out[tag] = u32(vo)
                elif typ == 5:
                    out[tag] = IFDRational(u32(vo), u32(vo + 4) or 1)
                elif typ == 10:
                    num, den = struct.unpack(bo + "ii", data[vo:vo + 8])
                    out[tag] = IFDRational(num, den or 1)
        except (struct.error, IndexError):
            pass
        return out

    ifd0 = read_ifd(u32(4))
    exif = read_ifd(ifd0[0x8769]) if isinstance(ifd0.get(0x8769), int) else {}
    return ifd0, exif


def main():
    if len(sys.argv) < 3:
        print("usage: raw_to_jpg.py <raw> <out.jpg> [yyyy:MM:dd HH:mm:ss]")
        return 1
    src, dst = sys.argv[1], sys.argv[2]
    fallback_date = sys.argv[3] if len(sys.argv) > 3 else ""

    ifd0, exif_src = read_tiff_tags(src)

    with rawpy.imread(src) as raw:
        rgb = raw.postprocess(use_camera_wb=True, output_bps=8)
    im = Image.fromarray(rgb)

    exif = Image.Exif()
    for tag in IFD0_COPY:
        if tag in ifd0:
            exif[tag] = ifd0[tag]
    exif[0x0112] = 1                                   # pixels already rotated
    exif[0x0131] = "raw_to_jpg.py (rawpy / LibRaw)"
    sub = {tag: exif_src[tag] for tag in EXIF_COPY if tag in exif_src}
    date = sub.get(0x9003) or ifd0.get(0x0132) or fallback_date
    if date:
        sub[0x9003] = date
        sub.setdefault(0x9004, date)
        exif[0x0132] = date
    exif[0x8769] = sub

    # write beside it and rename at the end, so a crash or full disk can't leave a
    # half-written JPG under the real name
    tmp = dst + ".rendering.tmp"
    try:
        im.save(tmp, "JPEG", quality=92, exif=exif.tobytes())
        os.replace(tmp, dst)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)
    print(f"rendered {src} -> {dst} ({im.width}x{im.height}, captured {date or 'unknown'})")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:          # any failure: say why, write nothing usable
        print(f"raw_to_jpg failed: {e!r}", file=sys.stderr)
        sys.exit(1)
