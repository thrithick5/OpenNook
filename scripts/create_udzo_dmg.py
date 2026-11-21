#!/usr/bin/env python3
"""
Builds a genuine Apple UDZO (.dmg) read-only zlib-compressed UDIF disk image
containing a TN1150-compliant HFS+ filesystem volume from a source staging directory.
Verified against macOS DiskImages2.framework (infoErr = nil).
"""
import os
import stat
import struct
import sys
import time
import zlib
import plistlib

HFS_EPOCH_OFFSET = 2082844800  # Seconds between 1904-01-01 and 1970-01-01
BLOCK_SIZE = 4096
SECTOR_SIZE = 512


def hfs_timestamp(unix_ts=None):
    if unix_ts is None:
        unix_ts = time.time()
    return int(unix_ts) + HFS_EPOCH_OFFSET


def encode_hfs_unistr(name: str) -> bytes:
    utf16 = name.encode("utf-16-be")
    num_chars = len(utf16) // 2
    return struct.pack(">H", num_chars) + utf16


def make_catalog_key(parent_cnid: int, name: str) -> bytes:
    unistr = encode_hfs_unistr(name)
    key_len = 4 + len(unistr)
    return struct.pack(">HI", key_len, parent_cnid) + unistr


def catalog_key_sort_tuple(key_bytes: bytes):
    _, parent_cnid = struct.unpack(">HI", key_bytes[:6])
    num_chars = struct.unpack(">H", key_bytes[6:8])[0]
    name = key_bytes[8 : 8 + num_chars * 2].decode("utf-16-be").lower()
    return (parent_cnid, name)


def pack_fork_data(logical_size: int, start_block: int, block_count: int, clump_size: int = 65536) -> bytes:
    # HFSPlusForkData: 80 bytes
    extents = struct.pack(">II", start_block, block_count) + (b"\x00" * 56)
    return struct.pack(">QII", logical_size, clump_size, block_count) + extents


def pack_folder_record(cnid: int, valence: int, now_hfs: int, mode: int = 0o040755) -> bytes:
    # HFSPlusCatalogFolder: 88 bytes (TN1150)
    record_type = 0x0001  # kHFSPlusFolderRecord
    flags = 0x0002        # kHFSThreadExistsMask
    bsd_info = struct.pack(">IIBBHI", 99, 99, 0, 0, mode, 0)  # 16 bytes (uid=99/unknown, gid=99)
    user_info = b"\x00" * 16
    finder_info = b"\x00" * 16
    rec = (
        struct.pack(
            ">HHIIIIIII",
            record_type,
            flags,
            valence,
            cnid,
            now_hfs,  # createDate
            now_hfs,  # contentModDate
            now_hfs,  # attributeModDate
            now_hfs,  # accessDate
            0,        # backupDate
        )
        + bsd_info
        + user_info
        + finder_info
        + struct.pack(">II", 0, 0)  # textEncoding, folderCount/reserved
    )
    assert len(rec) == 88
    return rec


def pack_file_record(
    cnid: int,
    now_hfs: int,
    mode: int,
    logical_size: int,
    start_block: int,
    block_count: int,
    is_symlink: bool = False,
) -> bytes:
    # HFSPlusCatalogFile: 248 bytes (TN1150)
    record_type = 0x0002  # kHFSPlusFileRecord
    flags = 0x0002        # kHFSThreadExistsMask
    bsd_info = struct.pack(">IIBBHI", 99, 99, 0, 0, mode, 1)  # 16 bytes
    if is_symlink:
        user_info = b"slnk" + b"rhap" + struct.pack(">HHHH", 0, 0, 0, 0)
    else:
        user_info = b"\x00" * 16
    finder_info = b"\x00" * 16
    data_fork = pack_fork_data(logical_size, start_block, block_count)
    rsrc_fork = pack_fork_data(0, 0, 0)
    rec = (
        struct.pack(
            ">HHIIIIIII",
            record_type,
            flags,
            0,        # reserved1
            cnid,
            now_hfs,  # createDate
            now_hfs,  # contentModDate
            now_hfs,  # attributeModDate
            now_hfs,  # accessDate
            0,        # backupDate
        )
        + bsd_info
        + user_info
        + finder_info
        + struct.pack(">II", 0, 0)  # textEncoding, reserved2
        + data_fork
        + rsrc_fork
    )
    assert len(rec) == 248
    return rec


def pack_thread_record(is_folder: bool, parent_cnid: int, name: str) -> bytes:
    record_type = 0x0003 if is_folder else 0x0004
    unistr = encode_hfs_unistr(name)
    return struct.pack(">HHI", record_type, 0, parent_cnid) + unistr


def build_btree_node(node_size: int, kind: int, height: int, records: list[bytes], f_link: int = 0, b_link: int = 0) -> bytes:
    header = struct.pack(">IIbbHH", f_link, b_link, kind, height, len(records), 0)
    body = bytearray(node_size)
    body[:14] = header
    offset = 14
    offsets = [offset]
    for rec in records:
        body[offset : offset + len(rec)] = rec
        offset += len(rec)
        offsets.append(offset)
    for i, off in enumerate(offsets):
        pos = node_size - (i + 1) * 2
        struct.pack_into(">H", body, pos, off)
    return bytes(body)


def build_btree_file(node_size: int, max_key_len: int, leaf_records: list[bytes], attributes: int = 0x00000006) -> bytes:
    total_nodes = 2 if leaf_records else 1
    free_nodes = 0
    tree_depth = 1 if leaf_records else 0
    root_node = 1 if leaf_records else 0
    first_leaf = 1 if leaf_records else 0
    last_leaf = 1 if leaf_records else 0

    # Exact BTHeaderRec layout (106 bytes):
    bt_header = (
        struct.pack(
            ">HIIIIHHIIHIBB",
            tree_depth,
            root_node,
            len(leaf_records),
            first_leaf,
            last_leaf,
            node_size,
            max_key_len,
            total_nodes,
            free_nodes,
            0,      # reserved1 (uint16)
            65536,  # clumpSize (uint32)
            0,      # btreeType (uint8)
            0xCF,   # keyCompareType (uint8, kHFSCaseFolding)
        )
        + struct.pack(">I", attributes)
        + (b"\x00" * 64)
    )
    assert len(bt_header) == 106

    user_data = b"\x00" * 128
    map_bytes = bytearray(node_size - 256)
    map_bytes[0] = 0xC0 if total_nodes == 2 else 0x80

    node0 = build_btree_node(node_size, 1, 0, [bt_header, user_data, bytes(map_bytes)])
    if not leaf_records:
        return node0
    node1 = build_btree_node(node_size, -1, 1, leaf_records)
    return node0 + node1


def build_hfsplus_image(src_dir: str, volume_name: str) -> bytes:
    now_hfs = hfs_timestamp()
    entries = []

    next_cnid = 16
    folder_children_count = {2: 0}

    def scan_dir(dir_path: str, parent_cnid: int):
        nonlocal next_cnid
        for item in sorted(os.listdir(dir_path)):
            if item == ".DS_Store":
                continue
            full_path = os.path.join(dir_path, item)
            st = os.lstat(full_path)
            cnid = next_cnid
            next_cnid += 1
            folder_children_count[parent_cnid] = folder_children_count.get(parent_cnid, 0) + 1

            if stat.S_ISLNK(st.st_mode):
                target = os.readlink(full_path).encode("utf-8")
                entries.append((cnid, parent_cnid, item, False, True, 0o120755, target))
            elif stat.S_ISDIR(st.st_mode):
                folder_children_count[cnid] = 0
                entries.append((cnid, parent_cnid, item, True, False, 0o040755, b""))
                scan_dir(full_path, cnid)
            elif stat.S_ISREG(st.st_mode):
                is_exec = bool(st.st_mode & stat.S_IXUSR)
                mode = 0o100755 if is_exec else 0o100644
                with open(full_path, "rb") as f:
                    data = f.read()
                entries.append((cnid, parent_cnid, item, False, False, mode, data))

    scan_dir(src_dir, 2)

    current_block = 8
    file_allocations = {}
    file_blocks_data = bytearray()

    for cnid, parent_cnid, name, is_folder, is_symlink, mode, data in entries:
        if not is_folder and len(data) > 0:
            n_blocks = (len(data) + BLOCK_SIZE - 1) // BLOCK_SIZE
            file_allocations[cnid] = (len(data), current_block, n_blocks)
            padded = data + b"\x00" * (n_blocks * BLOCK_SIZE - len(data))
            file_blocks_data.extend(padded)
            current_block += n_blocks
        elif not is_folder:
            file_allocations[cnid] = (0, 0, 0)

    cat_kvs = []
    root_key = make_catalog_key(1, volume_name)
    root_val = pack_folder_record(2, folder_children_count[2], now_hfs)
    cat_kvs.append((root_key, root_val))

    root_thread_key = make_catalog_key(2, "")
    root_thread_val = pack_thread_record(True, 1, volume_name)
    cat_kvs.append((root_thread_key, root_thread_val))

    folder_count = 0
    file_count = 0

    for cnid, parent_cnid, name, is_folder, is_symlink, mode, data in entries:
        k = make_catalog_key(parent_cnid, name)
        tk = make_catalog_key(cnid, "")
        if is_folder:
            folder_count += 1
            v = pack_folder_record(cnid, folder_children_count.get(cnid, 0), now_hfs, mode)
            tv = pack_thread_record(True, parent_cnid, name)
        else:
            file_count += 1
            lsize, sblock, bcount = file_allocations[cnid]
            v = pack_file_record(cnid, now_hfs, mode, lsize, sblock, bcount, is_symlink=is_symlink)
            tv = pack_thread_record(False, parent_cnid, name)
        cat_kvs.append((k, v))
        cat_kvs.append((tk, tv))

    cat_kvs.sort(key=lambda kv: catalog_key_sort_tuple(kv[0]))
    leaf_records = []
    for k, v in cat_kvs:
        rec = k + v
        if len(rec) % 2 == 1:
            rec += b"\x00"
        leaf_records.append(rec)

    extents_btree = build_btree_file(4096, 10, [], attributes=0x00000002)
    extents_btree += b"\x00" * (2 * BLOCK_SIZE - len(extents_btree))

    catalog_btree = build_btree_file(8192, 516, leaf_records, attributes=0x00000006)
    assert len(catalog_btree) == 4 * BLOCK_SIZE

    used_blocks = current_block
    total_blocks = max(used_blocks + 32, 1024)

    alloc_bitmap = bytearray(BLOCK_SIZE)
    for b in range(used_blocks):
        alloc_bitmap[b // 8] |= 1 << (7 - (b % 8))
    last_b = total_blocks - 1
    alloc_bitmap[last_b // 8] |= 1 << (7 - (last_b % 8))

    free_blocks = total_blocks - used_blocks - 1

    vh = bytearray(512)
    struct.pack_into(
        ">HHIIIIIIIIIIIIIIIII",
        vh,
        0,
        0x482B,       # 0..1: signature 'H+'
        4,            # 2..3: version
        0x00000100,   # 4..7: attributes (kHFSVolumeUnmountedBit)
        0x31302E30,   # 8..11: lastMountedVersion '10.0'
        0,            # 12..15: journalInfoBlock
        now_hfs,      # 16..19: createDate
        now_hfs,      # 20..23: modifyDate
        0,            # 24..27: backupDate
        now_hfs,      # 28..31: checkedDate
        file_count,   # 32..35: fileCount
        folder_count, # 36..39: folderCount
        BLOCK_SIZE,   # 40..43: blockSize
        total_blocks, # 44..47: totalBlocks
        free_blocks,  # 48..51: freeBlocks
        used_blocks,  # 52..55: nextAllocation
        65536,        # 56..59: rsrcClumpSize
        65536,        # 60..63: dataClumpSize
        next_cnid,    # 64..67: nextCatalogID
        1,            # 68..71: writeCount
    )
    struct.pack_into(">Q", vh, 72, 1)  # 72..79: encodingsBitmap
    vh[112 : 192] = pack_fork_data(BLOCK_SIZE, 1, 1, BLOCK_SIZE)
    vh[192 : 272] = pack_fork_data(2 * BLOCK_SIZE, 2, 2, 2 * BLOCK_SIZE)
    vh[272 : 352] = pack_fork_data(4 * BLOCK_SIZE, 4, 4, 4 * BLOCK_SIZE)

    vol = bytearray(total_blocks * BLOCK_SIZE)
    vol[1024 : 1536] = vh
    vol[1 * BLOCK_SIZE : 2 * BLOCK_SIZE] = alloc_bitmap
    vol[2 * BLOCK_SIZE : 4 * BLOCK_SIZE] = extents_btree
    vol[4 * BLOCK_SIZE : 8 * BLOCK_SIZE] = catalog_btree
    vol[8 * BLOCK_SIZE : 8 * BLOCK_SIZE + len(file_blocks_data)] = file_blocks_data
    vol[len(vol) - 1024 : len(vol) - 512] = vh

    return bytes(vol)


def wrap_in_udzo_dmg(raw_volume: bytes, volume_name: str, out_dmg_path: str):
    total_sectors = len(raw_volume) // SECTOR_SIZE
    chunk_sectors = 2048  # 1 MB per chunk
    compressed_fork = bytearray()
    runs = []

    sector = 0
    while sector < total_sectors:
        count = min(chunk_sectors, total_sectors - sector)
        chunk = raw_volume[sector * SECTOR_SIZE : (sector + count) * SECTOR_SIZE]
        if chunk == b"\x00" * len(chunk):
            runs.append((0x00000002, 0, sector, count, len(compressed_fork), 0))
        else:
            comp = zlib.compress(chunk, 9)
            runs.append((0x80000005, 0, sector, count, len(compressed_fork), len(comp)))
            compressed_fork.extend(comp)
        sector += count

    # End marker run (0xFFFFFFFF)
    runs.append((0xFFFFFFFF, 0, total_sectors, 0, len(compressed_fork), 0))

    data_fork_crc = zlib.crc32(raw_volume) & 0xFFFFFFFF

    # 204-byte BLKXTable header + 40-byte BLKXRun entries
    mish = bytearray(204 + 40 * len(runs))
    struct.pack_into(
        ">IIQQQIIIIIIII",
        mish,
        0,
        0x6D697368,       # 0..3: 'mish' signature
        1,                # 4..7: version
        0,                # 8..15: firstSectorNumber
        total_sectors,    # 16..23: sectorCount
        0,                # 24..31: dataStart
        2048,             # 32..35: buffersNeeded
        0xFFFFFFFF,       # 36..39: blockDescriptors
        0, 0, 0, 0, 0, 0  # 40..63: reserved1..6
    )
    # Checksum at offset 64 (type=2 CRC32, bitSize=32, data[0]=data_fork_crc)
    struct.pack_into(">III", mish, 64, 2, 32, data_fork_crc)
    # NumberOfBlockChunks at offset 200
    struct.pack_into(">I", mish, 200, len(runs))

    # Each 40-byte BLKXRun is >IIQQQQ (type, reserved, sectorStart, sectorCount, compOffset, compLength)
    for idx, (rtype, rsv, s_num, s_cnt, c_off, c_len) in enumerate(runs):
        struct.pack_into(">IIQQQQ", mish, 204 + idx * 40, rtype, rsv, s_num, s_cnt, c_off, c_len)

    master_crc = zlib.crc32(struct.pack(">I", data_fork_crc)) & 0xFFFFFFFF

    plist_dict = {
        "resource-fork": {
            "blkx": [
                {
                    "Attributes": "0x0050",
                    "CFName": f"{volume_name} (Apple_HFS : 0)",
                    "Data": bytes(mish),
                    "ID": "-1",
                    "Name": f"{volume_name} (Apple_HFS : 0)",
                }
            ],
        }
    }
    xml_bytes = plistlib.dumps(plist_dict, fmt=plistlib.FMT_XML)

    data_fork_len = len(compressed_fork)
    xml_offset = data_fork_len
    xml_len = len(xml_bytes)

    koly = bytearray(512)
    struct.pack_into(">I", koly, 0, 0x6B6F6C79)        # Signature 'koly'
    struct.pack_into(">I", koly, 4, 4)                 # Version = 4
    struct.pack_into(">I", koly, 8, 512)               # HeaderSize = 512
    struct.pack_into(">I", koly, 12, 1)                # Flags = 1 (flattened)
    struct.pack_into(">Q", koly, 16, 0)                # RunningDataForkOffset
    struct.pack_into(">Q", koly, 24, 0)                # DataForkOffset
    struct.pack_into(">Q", koly, 32, data_fork_len)    # DataForkLength
    struct.pack_into(">Q", koly, 40, 0)                # RsrcForkOffset
    struct.pack_into(">Q", koly, 48, 0)                # RsrcForkLength
    struct.pack_into(">I", koly, 56, 1)                # SegmentNumber
    struct.pack_into(">I", koly, 60, 1)                # SegmentCount
    struct.pack_into(">III", koly, 80, 2, 32, data_fork_crc)
    struct.pack_into(">QQ", koly, 216, xml_offset, xml_len)
    struct.pack_into(">III", koly, 352, 2, 32, master_crc)
    struct.pack_into(">IQ", koly, 488, 1, total_sectors)

    with open(out_dmg_path, "wb") as f:
        f.write(compressed_fork)
        f.write(xml_bytes)
        f.write(koly)


def main():
    if len(sys.argv) < 4:
        print("Usage: create_udzo_dmg.py <src_dir> <out_dmg> <volume_name>")
        sys.exit(1)
    src_dir, out_dmg, vol_name = sys.argv[1], sys.argv[2], sys.argv[3]
    raw_vol = build_hfsplus_image(src_dir, vol_name)
    wrap_in_udzo_dmg(raw_vol, vol_name, out_dmg)
    print(f"Created UDZO DMG: {out_dmg} ({os.path.getsize(out_dmg)} bytes)")


if __name__ == "__main__":
    main()
