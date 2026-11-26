#!/usr/bin/env python3
"""
KR-MP Android 15 APK Builder (Streaming Zero-Recompression Injector + 16KB Alignment + v1/v2/v3 Sign)
Injects client/UH.lua and client/kr_mp/** (~120 KB compressed) into FL 8.2.0 Android HD APK's
assets/game.love without touching any original game file, preserves 16KB page alignment on all
lib/**/*.so (Android 15 compliant) and 4-byte alignment on resources.arsc / assets/game.love,
then signs with official Google apksigner (APK Signature Scheme v1 + v2 + v3).
"""
import argparse
import os
import shutil
import struct
import subprocess
import sys
import time
import zipfile
import zlib

CHUNK_SIZE = 16 * 1024 * 1024  # 16 MB streaming buffer


def dos_time_date():
    t = time.localtime()
    dos_time = ((t.tm_hour & 0x1F) << 11) | ((t.tm_min & 0x3F) << 5) | ((t.tm_sec // 2) & 0x1F)
    dos_date = (((max(1980, t.tm_year) - 1980) & 0x7F) << 9) | ((t.tm_mon & 0x0F) << 5) | (t.tm_mday & 0x1F)
    return dos_time, dos_date


def collect_patch_files(client_dir):
    files = []
    uh_path = os.path.join(client_dir, "UH.lua")
    if not os.path.isfile(uh_path):
        raise FileNotFoundError(f"Missing {uh_path}")
    files.append(("UH.lua", uh_path))

    kr_mp_dir = os.path.join(client_dir, "kr_mp")
    for root, _, filenames in os.walk(kr_mp_dir):
        for fn in sorted(filenames):
            full = os.path.join(root, fn)
            rel = os.path.relpath(full, client_dir).replace("\\", "/")
            files.append((rel, full))
    return files


def build_zip_entry(arcname, data_bytes, compress=True):
    name_b = arcname.encode("utf-8")
    crc = zlib.crc32(data_bytes) & 0xFFFFFFFF
    uncomp_size = len(data_bytes)
    if compress:
        comp_obj = zlib.compressobj(level=6, method=zlib.DEFLATED, wbits=-15)
        payload = comp_obj.compress(data_bytes) + comp_obj.flush()
        comp_type = 8
    else:
        payload = data_bytes
        comp_type = 0
    comp_size = len(payload)
    dt, dd = dos_time_date()
    lfh = struct.pack(
        "<IHHHHHIIIHH",
        0x04034B50,  # Local file header signature
        20,          # Version needed to extract (2.0)
        0x0800,      # UTF-8 filename flag
        comp_type,
        dt, dd,
        crc,
        comp_size,
        uncomp_size,
        len(name_b),
        0,           # extra len
    ) + name_b
    return {
        "name_b": name_b,
        "comp_type": comp_type,
        "dt": dt,
        "dd": dd,
        "crc": crc,
        "comp_size": comp_size,
        "uncomp_size": uncomp_size,
        "lfh": lfh,
        "payload": payload,
    }


def make_cd_header(name_b, comp_type, flags, dt, dd, crc, comp_size, uncomp_size, lfh_offset, extra_cd=b"", ext_attr=0):
    return struct.pack(
        "<IHHHHHHIIIHHHHHII",
        0x02014B50,  # Central directory header signature
        20,          # Version made by
        20,          # Version needed
        flags,
        comp_type,
        dt, dd,
        crc,
        comp_size,
        uncomp_size,
        len(name_b),
        len(extra_cd),
        0,           # comment len
        0,           # disk start
        0,           # internal attrs
        ext_attr,
        lfh_offset,
    ) + name_b + extra_cd


def pad_to_align(base_offset, align):
    rem = base_offset % align
    return 0 if rem == 0 else (align - rem)


def is_meta_inf_sig(name):
    if not name.startswith("META-INF/"):
        return False
    upper = name.upper()
    if upper == "META-INF/MANIFEST.MF":
        return True
    for ext in (".SF", ".RSA", ".DSA", ".EC", ".MF"):
        if upper.endswith(ext):
            return True
    return False


def build_unsigned_apk(src_apk, client_dir, out_unsigned_apk):
    t0 = time.time()
    patch_files = collect_patch_files(client_dir)
    print(f"[APK] Preparing {len(patch_files)} KR-MP patch files from {client_dir}...")
    patch_entries = []
    for arcname, full in patch_files:
        with open(full, "rb") as f:
            data = f.read()
        # Keep PNGs stored or deflate? Deflate is fine inside game.love (PhysFS supports deflate on all entries)
        compress = not arcname.lower().endswith(".png")
        patch_entries.append(build_zip_entry(arcname, data, compress=compress))

    with zipfile.ZipFile(src_apk, "r") as zsrc:
        all_infos = zsrc.infolist()

    game_love_info = None
    so_infos = []
    other_infos = []
    for info in all_infos:
        if is_meta_inf_sig(info.filename):
            continue
        if info.filename == "assets/game.love":
            game_love_info = info
        elif info.filename.startswith("lib/") and info.filename.endswith(".so"):
            so_infos.append(info)
        else:
            other_infos.append(info)

    if game_love_info is None:
        raise RuntimeError("Source APK does not contain assets/game.love!")
    if game_love_info.compress_type != 0:
        raise RuntimeError(f"Expected assets/game.love STORED (0), got {game_love_info.compress_type}")

    # Order: 16KB-aligned native .so libs -> other APK assets/dex/resources.arsc -> assets/game.love LAST!
    ordered_regular = so_infos + other_infos
    cd_records = []

    with open(src_apk, "rb") as raw_in, open(out_unsigned_apk, "wb") as out:
        # 1. Copy all regular APK entries verbatim (preserving compression + applying Android 15 alignment!)
        for info in ordered_regular:
            raw_in.seek(info.header_offset)
            lfh_fixed = raw_in.read(30)
            sig, ver_need, flags, comp, dt, dd, crc, csz, usz, fnlen, exlen = struct.unpack("<IHHHHHIIIHH", lfh_fixed)
            if sig != 0x04034B50:
                raise RuntimeError(f"Invalid LFH signature for {info.filename}")
            orig_name = raw_in.read(fnlen)
            _orig_extra = raw_in.read(exlen)
            comp_payload = raw_in.read(info.compress_size)

            # Clear data descriptor flag (bit 3) since we write exact CRC & sizes in the local header
            clean_flags = flags & (~0x0008)
            lfh_offset = out.tell()

            # Compute required alignment for STORED entries
            align = 1
            if info.compress_type == 0:
                if info.filename.startswith("lib/") and info.filename.endswith(".so"):
                    align = 16384  # Android 15 16KB ELF page alignment!
                else:
                    align = 4      # resources.arsc and other stored assets

            header_end_no_pad = lfh_offset + 30 + len(orig_name)
            pad = pad_to_align(header_end_no_pad, align)
            extra_lfh = b"\x00" * pad

            new_lfh = struct.pack(
                "<IHHHHHIIIHH",
                0x04034B50,
                ver_need,
                clean_flags,
                info.compress_type,
                dt, dd,
                info.CRC,
                info.compress_size,
                info.file_size,
                len(orig_name),
                len(extra_lfh),
            ) + orig_name + extra_lfh

            out.write(new_lfh)
            data_pos = out.tell()
            if align > 1 and (data_pos % align) != 0:
                raise RuntimeError(f"Alignment mismatch for {info.filename}: offset={data_pos} align={align}")
            out.write(comp_payload)

            cd_records.append(make_cd_header(
                orig_name, info.compress_type, clean_flags, dt, dd,
                info.CRC, info.compress_size, info.file_size, lfh_offset,
                extra_cd=b"", ext_attr=info.external_attr,
            ))

        # 2. Stream-patch assets/game.love directly into output APK!
        raw_in.seek(game_love_info.header_offset)
        _, _, _, _, gl_dt, gl_dd, _, _, _, gl_fnlen, gl_exlen = struct.unpack("<IHHHHHIIIHH", raw_in.read(30))
        gl_data_start = game_love_info.header_offset + 30 + gl_fnlen + gl_exlen
        gl_old_size = game_love_info.file_size

        # Parse old game.love EOCD
        raw_in.seek(gl_data_start + gl_old_size - 128)
        gl_tail = raw_in.read(128)
        eocd_idx = gl_tail.rfind(b"PK\x05\x06")
        if eocd_idx < 0:
            raise RuntimeError("Cannot find EOCD inside assets/game.love")
        _, d0, d1, old_nd, old_nt, old_cd_sz, old_cd_off, old_cmt_len = struct.unpack(
            "<IHHHHIIH", gl_tail[eocd_idx:eocd_idx + 22]
        )
        if old_cd_off == 0xFFFFFFFF or old_nt == 0xFFFF:
            raise RuntimeError("Source game.love already exceeds ZIP32 limits")

        # Parse old Central Directory entries of game.love so we cleanly support BOTH:
        #   (a) stock FL 8.2.0 APK (no UH.lua / kr_mp/* yet), AND
        #   (b) re-patching an existing KR-MP APK (strips previous tail UH.lua / kr_mp/* with zero bloat!)
        raw_in.seek(gl_data_start + old_cd_off)
        old_cd_bytes = raw_in.read(old_cd_sz)
        patch_name_set = {pe["name_b"] for pe in patch_entries}
        kept_cd_chunks = []
        kept_count = 0
        stripped_min_off = None
        kept_max_end = 0
        pos_cd = 0
        while pos_cd < len(old_cd_bytes):
            if old_cd_bytes[pos_cd:pos_cd + 4] != b"PK\x01\x02":
                raise RuntimeError(f"Corrupt central directory inside assets/game.love at {pos_cd}")
            (
                _sig, _vm, _vn, _fl, _cm, _mt, _md, _crc,
                e_csz, e_usz, e_fnlen, e_exlen, e_cmlen,
                _ds, _ia, _ea, e_lh_off
            ) = struct.unpack("<IHHHHHHIIIHHHHHII", old_cd_bytes[pos_cd:pos_cd + 46])
            rec_end = pos_cd + 46 + e_fnlen + e_exlen + e_cmlen
            ename = old_cd_bytes[pos_cd + 46:pos_cd + 46 + e_fnlen]
            real_off = e_lh_off
            if real_off == 0xFFFFFFFF and e_exlen > 0:
                ex = old_cd_bytes[pos_cd + 46 + e_fnlen:pos_cd + 46 + e_fnlen + e_exlen]
                ep = 0
                while ep + 4 <= len(ex):
                    hid, hsz = struct.unpack("<HH", ex[ep:ep + 4])
                    if hid == 0x0001:
                        zpos = ep + 4
                        if e_usz == 0xFFFFFFFF: zpos += 8
                        if e_csz == 0xFFFFFFFF: zpos += 8
                        if zpos + 8 <= ep + 4 + hsz:
                            real_off = struct.unpack("<Q", ex[zpos:zpos + 8])[0]
                        break
                    ep += 4 + hsz
            is_old_krmp = (ename == b"UH.lua" or ename.startswith(b"kr_mp/") or ename in patch_name_set)
            if is_old_krmp:
                if stripped_min_off is None or real_off < stripped_min_off:
                    stripped_min_off = real_off
            else:
                kept_cd_chunks.append(old_cd_bytes[pos_cd:rec_end])
                kept_count += 1
                if real_off > kept_max_end:
                    kept_max_end = real_off
            pos_cd = rec_end

        if stripped_min_off is not None:
            if kept_max_end >= stripped_min_off:
                raise RuntimeError("Cannot strip interleaved old KR-MP entries safely; use stock APK.")
            stream_end_off = stripped_min_off
            print(f"[APK] Re-patching existing KR-MP APK: stripping {old_nt - kept_count} old patch entries at offset {stream_end_off:,}...")
        else:
            stream_end_off = old_cd_off

        kept_cd_bytes = b"".join(kept_cd_chunks)

        # Write local file header for assets/game.love (4-byte aligned, STORED, CRC & sizes patched after stream)
        gl_name_b = b"assets/game.love"
        gl_lfh_off = out.tell()
        gl_pad = pad_to_align(gl_lfh_off + 30 + len(gl_name_b), 4)
        gl_extra = b"\x00" * gl_pad
        gl_dt_now, gl_dd_now = dos_time_date()
        out.write(struct.pack(
            "<IHHHHHIIIHH",
            0x04034B50, 20, 0, 0, gl_dt_now, gl_dd_now,
            0, 0, 0, len(gl_name_b), len(gl_extra),
        ) + gl_name_b + gl_extra)

        gl_out_start = out.tell()
        assert gl_out_start % 4 == 0
        gl_crc = 0

        def write_gl(chunk):
            nonlocal gl_crc
            out.write(chunk)
            gl_crc = zlib.crc32(chunk, gl_crc) & 0xFFFFFFFF

        # Stream original game.love bytes [0 .. stream_end_off)
        print(f"[APK] Streaming {stream_end_off / (1024**3):.2f} GiB of assets/game.love...")
        raw_in.seek(gl_data_start)
        remaining = stream_end_off
        copied = 0
        next_report = 512 * 1024 * 1024
        while remaining > 0:
            to_read = CHUNK_SIZE if remaining > CHUNK_SIZE else remaining
            buf = raw_in.read(to_read)
            if not buf:
                raise RuntimeError("Unexpected EOF streaming assets/game.love")
            write_gl(buf)
            remaining -= len(buf)
            copied += len(buf)
            if copied >= next_report:
                print(f"      streamed {copied / (1024**3):.2f} / {stream_end_off / (1024**3):.2f} GiB...")
                next_report += 512 * 1024 * 1024

        # Append our fresh KR-MP entries right at stream_end_off!
        new_gl_cd_parts = [kept_cd_bytes]
        cur_gl_pos = stream_end_off
        for pe in patch_entries:
            write_gl(pe["lfh"])
            write_gl(pe["payload"])
            new_gl_cd_parts.append(make_cd_header(
                pe["name_b"], pe["comp_type"], 0x0800, pe["dt"], pe["dd"],
                pe["crc"], pe["comp_size"], pe["uncomp_size"], cur_gl_pos,
            ))
            cur_gl_pos += len(pe["lfh"]) + len(pe["payload"])

        new_gl_cd_off = cur_gl_pos
        new_gl_cd_bytes = b"".join(new_gl_cd_parts)
        new_gl_cd_sz = len(new_gl_cd_bytes)
        new_gl_entries = kept_count + len(patch_entries)

        write_gl(new_gl_cd_bytes)

        # Write ZIP64 EOCD Record (56 bytes) + ZIP64 EOCD Locator (20 bytes) + Standard EOCD (22 bytes)
        zip64_eocd_off = new_gl_cd_off + new_gl_cd_sz
        zip64_eocd = struct.pack(
            "<IQHHIIQQQQ",
            0x06064B50,       # ZIP64 EOCD signature
            44,               # size of remaining record
            45, 45,           # version made by / needed (4.5)
            0, 0,             # disk numbers
            new_gl_entries,
            new_gl_entries,
            new_gl_cd_sz,
            new_gl_cd_off,
        )
        zip64_loc = struct.pack(
            "<IIQI",
            0x07064B50,       # ZIP64 EOCD Locator signature
            0,                # disk with ZIP64 EOCD
            zip64_eocd_off,
            1,                # total disks
        )
        std_eocd = struct.pack(
            "<IHHHHIIH",
            0x06054B50,
            0, 0,
            new_gl_entries,
            new_gl_entries,
            new_gl_cd_sz,
            new_gl_cd_off,
            0,
        )
        write_gl(zip64_eocd)
        write_gl(zip64_loc)
        write_gl(std_eocd)

        gl_new_size = out.tell() - gl_out_start
        if gl_new_size >= 0xFFFFFFFF:
            raise RuntimeError(f"Patched game.love exceeded 4 GiB ZIP32 limit: {gl_new_size}")

        # Seek back and patch assets/game.love LFH CRC32 & size
        gl_end_pos = out.tell()
        out.seek(gl_lfh_off + 14)
        out.write(struct.pack("<III", gl_crc, gl_new_size, gl_new_size))
        out.seek(gl_end_pos)

        cd_records.append(make_cd_header(
            gl_name_b, 0, 0, gl_dt_now, gl_dd_now,
            gl_crc, gl_new_size, gl_new_size, gl_lfh_off,
        ))

        # 3. Write APK Central Directory & EOCD
        apk_cd_off = out.tell()
        if apk_cd_off >= 0xFFFFFFFF:
            raise RuntimeError(f"APK CD offset exceeded 4 GiB ZIP32 limit: {apk_cd_off}")
        apk_cd_bytes = b"".join(cd_records)
        out.write(apk_cd_bytes)
        apk_eocd = struct.pack(
            "<IHHHHIIH",
            0x06054B50,
            0, 0,
            len(cd_records),
            len(cd_records),
            len(apk_cd_bytes),
            apk_cd_off,
            0,
        )
        out.write(apk_eocd)
        final_unsigned_size = out.tell()

    elapsed = time.time() - t0
    print(f"[APK] Unsigned APK built in {elapsed:.1f}s -> {out_unsigned_apk} ({final_unsigned_size:,} bytes, +{gl_new_size - gl_old_size:,} bytes)")
    return final_unsigned_size


def ensure_keystore(ks_path, alias, storepass):
    if os.path.isfile(ks_path):
        print(f"[SIGN] Reusing persistent release keystore: {ks_path}")
        return
    os.makedirs(os.path.dirname(ks_path), exist_ok=True)
    print(f"[SIGN] Generating persistent local release keystore: {ks_path}")
    cmd = [
        "keytool", "-genkeypair", "-v",
        "-keystore", ks_path,
        "-storetype", "PKCS12",
        "-alias", alias,
        "-keyalg", "RSA",
        "-keysize", "2048",
        "-validity", "10000",
        "-storepass", storepass,
        "-keypass", storepass,
        "-dname", "CN=KR-MP Coop, OU=ChiyuStudio, O=KR-MP, L=Beijing, ST=Beijing, C=CN",
    ]
    subprocess.run(cmd, check=True)


def verify_apk_layout(apk_path):
    print(f"[VERIFY] Checking Android 15 alignment & game.love integrity in {apk_path}...")
    with zipfile.ZipFile(apk_path, "r") as apk:
        with open(apk_path, "rb") as raw:
            for info in apk.infolist():
                if info.filename.startswith("lib/") and info.filename.endswith(".so"):
                    raw.seek(info.header_offset)
                    _, _, _, _, _, _, _, _, _, fnlen, exlen = struct.unpack("<IHHHHHIIIHH", raw.read(30))
                    data_off = info.header_offset + 30 + fnlen + exlen
                    if info.compress_type != 0 or (data_off % 16384) != 0:
                        raise RuntimeError(f"SO alignment check FAILED: {info.filename} comp={info.compress_type} off={data_off}")
                elif info.filename == "resources.arsc":
                    raw.seek(info.header_offset)
                    _, _, _, _, _, _, _, _, _, fnlen, exlen = struct.unpack("<IHHHHHIIIHH", raw.read(30))
                    data_off = info.header_offset + 30 + fnlen + exlen
                    if info.compress_type != 0 or (data_off % 4) != 0:
                        raise RuntimeError(f"resources.arsc alignment FAILED: comp={info.compress_type} off={data_off}")

            gi = apk.getinfo("assets/game.love")
            raw.seek(gi.header_offset)
            _, _, _, _, _, _, _, _, _, fnlen, exlen = struct.unpack("<IHHHHHIIIHH", raw.read(30))
            gl_start = gi.header_offset + 30 + fnlen + exlen
            if gi.compress_type != 0 or (gl_start % 4) != 0:
                raise RuntimeError(f"assets/game.love alignment FAILED: comp={gi.compress_type} off={gl_start}")

            class SubFile:
                def __init__(self, f, start, length):
                    self.f, self.start, self.length, self.pos = f, start, length, 0
                def seekable(self): return True
                def readable(self): return True
                def seek(self, offset, whence=0):
                    if whence == 0: self.pos = offset
                    elif whence == 1: self.pos += offset
                    elif whence == 2: self.pos = self.length + offset
                    self.pos = max(0, min(self.length, self.pos))
                    return self.pos
                def tell(self): return self.pos
                def read(self, n=-1):
                    if n is None or n < 0 or self.pos + n > self.length:
                        n = self.length - self.pos
                    self.f.seek(self.start + self.pos)
                    data = self.f.read(n)
                    self.pos += len(data)
                    return data

            sf = SubFile(raw, gl_start, gi.file_size)
            with zipfile.ZipFile(sf, "r") as gl:
                must_have = [
                    "UH.lua",
                    "kr_mp/boot.lua",
                    "kr_mp/proto.lua",
                    "kr_mp/voice.lua",
                    "kr_mp/lobby_ui.lua",
                    "kr_mp/overlay.lua",
                    "kr_mp/ui_assets.lua",
                    "kr_mp/assets/wax_seal_red.png",
                    "main.lua",
                    "all/director.lua",
                    "mod.lua",
                ]
                for item in must_have:
                    b = gl.read(item)
                    if not b:
                        raise RuntimeError(f"Empty or missing entry inside game.love: {item}")
                print(f"[VERIFY] game.love OK! ({len(gl.namelist())} entries; UH.lua + kr_mp/* + original FL 8.2.0 verified)")
    print("[VERIFY] All .so 16KB-aligned, resources.arsc & game.love 4B-aligned!")


def main():
    parser = argparse.ArgumentParser(description="Build signed KR-MP Android 15 APK from stock FL 8.2.0 HD APK")
    parser.add_argument("--src-apk", required=True, help="Path to original FL 8.2.0 Android HD APK")
    parser.add_argument("--client-dir", default=os.path.join(os.path.dirname(__file__), "..", "client"))
    parser.add_argument("--out-apk", required=True, help="Output signed APK path")
    parser.add_argument("--apksigner-jar", default=os.path.join(os.path.dirname(__file__), "..", ".android_tools", "apksigner.jar"))
    parser.add_argument("--keystore", default=os.path.join(os.path.dirname(__file__), "..", ".android_tools", "kr_mp_android.jks"))
    parser.add_argument("--keep-unsigned", action="store_true")
    args = parser.parse_args()

    src_apk = os.path.abspath(args.src_apk)
    client_dir = os.path.abspath(args.client_dir)
    out_apk = os.path.abspath(args.out_apk)
    apksigner_jar = os.path.abspath(args.apksigner_jar)
    ks_path = os.path.abspath(args.keystore)

    if not os.path.isfile(src_apk):
        raise FileNotFoundError(f"Source APK not found: {src_apk}")
    if not os.path.isfile(apksigner_jar):
        raise FileNotFoundError(f"apksigner.jar not found: {apksigner_jar}")

    os.makedirs(os.path.dirname(out_apk), exist_ok=True)
    unsigned_apk = out_apk + ".unsigned.tmp"
    signed_tmp = out_apk + ".signed.tmp"

    try:
        build_unsigned_apk(src_apk, client_dir, unsigned_apk)
        verify_apk_layout(unsigned_apk)

        ks_alias = "krmp_release"
        ks_pass = "krmp2026android"
        ensure_keystore(ks_path, ks_alias, ks_pass)

        print(f"[SIGN] Running official Google apksigner (v1 + v2 + v3) -> {out_apk} ...")
        t1 = time.time()
        sign_cmd = [
            "java", "-Xmx1536m", "-jar", apksigner_jar, "sign",
            "--ks", ks_path,
            "--ks-key-alias", ks_alias,
            "--ks-pass", f"pass:{ks_pass}",
            "--key-pass", f"pass:{ks_pass}",
            "--v1-signing-enabled", "true",
            "--v2-signing-enabled", "true",
            "--v3-signing-enabled", "true",
            "--v4-signing-enabled", "false",
            "--out", signed_tmp,
            unsigned_apk,
        ]
        subprocess.run(sign_cmd, check=True)
        print(f"[SIGN] Signed in {time.time() - t1:.1f}s!")

        print("[SIGN] Verifying final APK signature with apksigner verify...")
        ver_cmd = [
            "java", "-Xmx1024m", "-jar", apksigner_jar, "verify",
            "--verbose", "--print-certs", signed_tmp,
        ]
        subprocess.run(ver_cmd, check=True)
        verify_apk_layout(signed_tmp)
        os.replace(signed_tmp, out_apk)
        idsig = out_apk + ".idsig"
        if os.path.exists(idsig):
            os.remove(idsig)
        print(f"\n[DONE] Signed Android 15 APK ready: {out_apk} ({os.path.getsize(out_apk):,} bytes)")
    finally:
        if not args.keep_unsigned and os.path.exists(unsigned_apk):
            os.remove(unsigned_apk)
        if os.path.exists(signed_tmp):
            os.remove(signed_tmp)


if __name__ == "__main__":
    main()
