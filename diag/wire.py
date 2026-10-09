#!/usr/bin/env python3
"""wire.py: a passive observer of the Ergo P2P messages crossing the rig's links. Capture in the hot path, decode
offline; it never sends, injects or alters a packet.

  python3 diag/wire.py capture <iface> <out.pcap> [--stats <file>] [--rcvbuf <bytes>]
  python3 diag/wire.py decode <run dir> [--magic <hex>] [--names ip=name,...] [--out <messages.jsonl>]

capture: one AF_PACKET socket bound to one interface (the rig runs one per link, on the link's `a` end, inside that
node's namespace; it sees both directions). Every packet is written to a standard libpcap file (Ethernet link type)
with time.time() at receive as the record's sec/usec: the decoder's t_ms is on the same epoch-ms wall clock as
events.jsonl's `t`. SO_RCVBUF is raised to net.core.rmem_max (SO_RCVBUFFORCE is refused inside a user namespace);
SO_TIMESTAMPNS gives the kernel's receive time beside it, and the stats file reports the skew. PACKET_STATISTICS is
read every second (the kernel clears it on read) into a series of [t_ms, packets, drops], where packets includes the
dropped ones; the totals and the series go to --stats (default <out>.stats.json) every 10 s and at stop (SIGTERM or
SIGINT). A capture drop turns "never sent" into "not seen", so every summary carries the drop count.

decode: reads <run dir>/wire/<a>-<b>.pcap (+ .stats.json) and <run dir>/effective.json (magic, node addresses) and
writes <run dir>/messages.jsonl (one record per line, all links, ordered by t_ms) and <run dir>/wire/summary.json.
Per TCP connection (4-tuple from its SYN; each record carries `conn`, so reconnects are visible), each direction is
reassembled by sequence number (retransmits and out-of-order segments handled). A hole is declared a `gap` once the
receiver's ACK passes it (it was delivered and not captured) or at the stream's end; decoding then resyncs. Each
direction opens with the handshake, which is NOT framed (raw HandshakeSerializer bytes) and is parsed structurally;
after it come frames: magic 4, code 1, length 4 (big-endian), then checksum 4 (Blake2b-256 prefix) and data only
when length > 0. A position that does not start a valid frame is a `desync`; a resync candidate is accepted only if
its frame passes its checksum (or is a length-0 frame of a known code followed by an accepted frame), and a length
outside [0, MAX_MESSAGE_SIZE] is refused at once. A partial frame at a connection's end or the capture's stop is a
`tail`. A frame split over segments takes the time of the segment that completes it.

Records ("kind"): handshake {agent, version, node_name, declared_address, features, session_magic_ok, len};
frame {code, name, len, checksum_ok (null for length 0), ...parsed}; gap {bytes, lost}; desync {why, at};
resync {skipped}; tail {bytes}. Every record has t_ms, link, conn, from, to. Parsed fields: SyncInfo (65) sync
v1 + ids (a count) or v2 + headers + heights; Inv (55) and RequestModifier (22) type_id + count + modifier_ids
(hex); Modifiers (33) type_id + count + modifier_ids (+ heights and tx_section_ids for headers, type 101: the id of
each header's BlockTransactions section, which a type-102 request names); GetPeers (1) nothing; Peers (2) peers; Matrix (weak-blocks): InputBlock (100)
version, input_block_id, height, ordering_parent_id, prev_input_block_id, weak_tx_ids (a count, null when not carried) + weak_ids,
and from version 2 unparsed_len (+ uncle_ids when the field reads as the uncles prototype's: a count <= 2, then ids); InputBlockTxIds (102) and InputBlockTxsRequest
(105) input_block_id, count, weak_ids; InputBlockTxs (104) input_block_id, count; OrderingBlock (106) version,
ordering_block_id, height, tx_section_id, non_broadcast_txs. Other codes: code and len only.
Layouts are those of the v6.0.6 reference node. Standard library only.
"""
import bisect
import hashlib
import json
import os
import signal
import socket
import struct
import sys
import time

MAX_MESSAGE_SIZE = 2048576 * 4 * 2   # MessageConstants.MaxMessageSize = ModifiersSpec.maxMsgSizeWithReserve * 2
MAX_HANDSHAKE = 8096                 # HandshakeSerializer.maxHandshakeSize
CODES = {1: "GetPeers", 2: "Peers", 22: "RequestModifier", 33: "Modifiers", 55: "Inv", 65: "SyncInfo",
         76: "GetSnapshotsInfo", 77: "SnapshotsInfo", 78: "GetManifest", 79: "Manifest", 80: "GetUtxoSnapshotChunk",
         81: "UtxoSnapshotChunk", 90: "GetNipopowProof", 91: "NipopowProof",
         # Matrix (weak-blocks line, e.g. a1bd938e): input blocks and ordering-block announcements
         100: "InputBlock", 102: "InputBlockTxIds", 104: "InputBlockTxs", 105: "InputBlockTxsRequest",
         106: "OrderingBlock"}   # 75 (Handshake) is never framed
WEAK_ID_LENGTH = 6   # ErgoTransaction.WeakIdLength (weak-blocks): 3 bytes of the tx id, then 3 of its witness id
MAX_UNCLES = 2       # InputBlockUncles.MaxUncles (the uncles prototype, announcement version 2)
BLOCK_SECTIONS = (101, 102, 104, 108)   # header, block transactions, proofs, extension; 2 = transaction
FEATURES = {2: "local_address", 3: "session_id", 4: "rest_api_url", 16: "mode"}
DEFAULT_MAGIC = bytes([112, 101, 101, 114])   # the rig's default ("peer")

# pcap
PCAP_MAGIC = 0xA1B2C3D4
LINKTYPE_ETHERNET, LINKTYPE_RAW = 1, 101
SNAPLEN = 262144   # above a 64 KB GSO super-frame

# Linux socket constants the socket module may not export
SOL_PACKET, PACKET_STATISTICS = 263, 6
SO_TIMESTAMPNS = getattr(socket, "SO_TIMESTAMPNS", 35)
ETH_P_ALL = 0x0003


# ---------------------------------------------------------------------------------------------------------- capture
def pcap_header(linktype=LINKTYPE_ETHERNET, snaplen=SNAPLEN):
    return struct.pack("<IHHiIII", PCAP_MAGIC, 2, 4, 0, 0, snaplen, linktype)


def pcap_ts(t):
    """(sec, usec) of a time.time() value, as a record header carries it; the decoder's t_ms is sec*1000 + usec//1000"""
    sec = int(t)
    usec = int(round((t - sec) * 1e6))
    if usec >= 1000000:
        sec, usec = sec + 1, usec - 1000000
    return sec, usec


def pcap_record(t, data, origlen=None):
    sec, usec = pcap_ts(t)
    return struct.pack("<IIII", sec, usec, len(data), len(data) if origlen is None else origlen) + data


def rmem_max():
    try:
        with open("/proc/sys/net/core/rmem_max") as fh:
            return int(fh.read().split()[0])
    except (OSError, ValueError, IndexError):
        return None


def capture(iface, out, stats_path=None, rcvbuf=None):
    if not stats_path:
        stats_path = (out[:-5] if out.endswith(".pcap") else out) + ".stats.json"
    # protocol 0 until bound: an unbound ETH_P_ALL socket would queue packets from every interface in the namespace
    s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, 0)
    want = rcvbuf if rcvbuf is not None else (rmem_max() or 0)
    if want:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, want)
    got = s.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)
    ts_ok = True
    try:
        s.setsockopt(socket.SOL_SOCKET, SO_TIMESTAMPNS, 1)
    except OSError:
        ts_ok = False
    s.bind((iface, ETH_P_ALL))
    s.getsockopt(SOL_PACKET, PACKET_STATISTICS, 8)   # clear anything counted before the bind
    s.settimeout(0.25)
    st = {"iface": iface, "pcap": os.path.basename(out), "started_ms": int(time.time() * 1000), "stopped_ms": None,
          "rcvbuf_requested": want or None, "rcvbuf_effective": got, "kernel_timestamps": ts_ok,
          "packets": 0, "drops": 0, "records": 0, "bytes": 0, "cut_at_snaplen": 0,
          "skew_ms": {"n": 0, "mean": None, "min": None, "max": None}, "series": []}
    skew_sum, skew_min, skew_max = 0.0, None, None
    stop = []
    signal.signal(signal.SIGTERM, lambda *_: stop.append(1))
    signal.signal(signal.SIGINT, lambda *_: stop.append(1))
    buf = bytearray(SNAPLEN)
    ancsize = socket.CMSG_SPACE(16)

    def read_stats():
        p, d = struct.unpack("II", s.getsockopt(SOL_PACKET, PACKET_STATISTICS, 8))
        st["packets"] += p
        st["drops"] += d
        st["series"].append([int(time.time() * 1000), p, d])

    def write_stats():
        st["skew_ms"] = {"n": st["skew_ms"]["n"], "mean": None if not st["skew_ms"]["n"] else
                         round(skew_sum / st["skew_ms"]["n"], 3), "min": skew_min, "max": skew_max}
        tmp = stats_path + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(st, fh)
        os.replace(tmp, stats_path)

    with open(out, "wb", buffering=1 << 20) as fh:
        fh.write(pcap_header())
        fh.flush()   # the rig waits for a non-empty file before it launches the nodes
        next_tick = time.time() + 1.0
        ticks = 0
        draining = False
        while True:
            if stop and not draining:   # at stop, read what is already queued, so packets = records + drops
                draining = True
                drain_end = time.time() + 2.0   # a busy link never empties: bounded
                s.setblocking(False)
            if draining and time.time() > drain_end:
                break
            try:
                n, anc, _flags, _addr = s.recvmsg_into([buf], ancsize, socket.MSG_TRUNC)
                now = time.time()
                cap = min(n, SNAPLEN)
                if n > SNAPLEN:
                    st["cut_at_snaplen"] += 1
                fh.write(pcap_record(now, bytes(buf[:cap]), n))
                st["records"] += 1
                st["bytes"] += cap
                for level, typ, data in anc:
                    if level == socket.SOL_SOCKET and typ == SO_TIMESTAMPNS and len(data) >= 16:
                        ks, kns = struct.unpack("qq", data[:16])
                        sk = round((now - (ks + kns / 1e9)) * 1000, 3)
                        st["skew_ms"]["n"] += 1
                        skew_sum += sk
                        skew_min = sk if skew_min is None else min(skew_min, sk)
                        skew_max = sk if skew_max is None else max(skew_max, sk)
            except BlockingIOError:
                break                  # drained
            except socket.timeout:
                now = time.time()
            except InterruptedError:
                continue
            if now >= next_tick:
                read_stats()
                fh.flush()
                next_tick = now + 1.0
                ticks += 1
                if ticks % 10 == 0:
                    write_stats()
        read_stats()
    st["stopped_ms"] = int(time.time() * 1000)
    write_stats()
    return 0


# ----------------------------------------------------------------------------------------------------------- readers
class NeedMore(Exception):
    """The bytes end before the structure does."""


class Reader:
    def __init__(self, b, pos=0):
        self.b, self.pos = b, pos

    def take(self, n):
        if n < 0:
            raise ValueError("negative length")
        if self.pos + n > len(self.b):
            raise NeedMore()
        v = bytes(self.b[self.pos:self.pos + n])
        self.pos += n
        return v

    def u8(self):
        if self.pos >= len(self.b):
            raise NeedMore()
        v = self.b[self.pos]
        self.pos += 1
        return v

    def i8(self):
        v = self.u8()
        return v - 256 if v > 127 else v

    def vlq(self):
        v = shift = 0
        while True:
            c = self.u8()
            v |= (c & 0x7F) << shift
            if not c & 0x80:
                return v
            shift += 7
            if shift > 63:
                raise ValueError("VLQ too long")

    def short_string(self):
        n = self.u8()
        return self.take(n).decode("utf-8")

    @property
    def remaining(self):
        return len(self.b) - self.pos


def header_height(hb):
    """Height of a serialized header (HeaderSerializer, v6.0.6): version 1 + parentId 32 + ADProofsRoot 32 +
    transactionsRoot 32 + stateRoot 33, timestamp (VLQ), extensionRoot 32, nBits 4, height (VLQ)."""
    r = Reader(hb, 130)
    r.vlq()
    r.take(36)
    return r.vlq()


def transactions_section_id(header_id_hex, transactions_root):
    """The id of a header's BlockTransactions section (type 102): Blake2b-256(102 ++ header id ++ transactionsRoot),
    NonHeaderBlockSection.computeId as Header.transactionsId uses it. A RequestModifier or Modifiers frame of type 102
    names this id, never the header's."""
    return hashlib.blake2b(bytes([102]) + bytes.fromhex(header_id_hex) + transactions_root, digest_size=32).hexdigest()


def header_tx_root(hb):
    """transactionsRoot of a serialized header (after version 1, parentId 32, ADProofsRoot 32)."""
    return bytes(hb[65:97])


def header_span(r):
    """Read one full serialized header from Reader r (HeaderSerializer: serializeWithoutPow, then the PoW solution by
    version) and return (header id hex, height, version). The id is Blake2b-256 of the header's bytes (Header.id).
    The header's bytes are left in r.last_header (for header_tx_root)."""
    start = r.pos
    version = r.u8()
    r.take(32 + 32 + 32 + 33)              # parentId, ADProofsRoot, transactionsRoot, stateRoot
    r.vlq()                                # timestamp
    r.take(32 + 4)                         # extensionRoot, nBits
    height = r.vlq()
    r.take(3)                              # votes
    if version > 1:
        r.take(r.u8())                     # unparsed bytes (length-prefixed)
        r.take(33 + 8)                     # Autolykos v2: pk, nonce
    else:
        r.take(33 + 33 + 8)                # Autolykos v1: pk, w, nonce
        r.take(r.u8())                     # d
    r.last_header = bytes(r.b[start:r.pos])
    hid = hashlib.blake2b(r.last_header, digest_size=32).hexdigest()
    return hid, height, version


def parse_handshake(b, magic):
    """(record fields, bytes consumed) of a handshake at the start of b; NeedMore if b ends inside it, ValueError if
    the bytes cannot be one."""
    r = Reader(b)
    r.vlq()   # time
    try:
        agent = r.short_string()
        ver = r.take(3)
        node_name = r.short_string()
    except UnicodeDecodeError:
        raise ValueError("handshake strings are not UTF-8")
    if not agent or not agent.isprintable():
        raise ValueError("handshake agent empty or not printable")
    opt = r.u8()
    addr = None
    if opt == 1:
        size = r.u8()
        if size not in (8, 20):
            raise ValueError(f"declared address size {size}")
        ab = r.take(size - 4)
        port = r.vlq()
        addr = (socket.inet_ntop(socket.AF_INET if len(ab) == 4 else socket.AF_INET6, ab) + f":{port}")
    elif opt != 0:
        raise ValueError(f"option byte {opt}")
    nf = r.i8()
    if nf < 0:
        raise ValueError("negative feature count")
    feats, session_ok = [], None
    for _ in range(nf):
        fid = r.i8()
        ln = r.vlq()
        if ln > 0xFFFF:
            raise ValueError("feature length above UShort")
        fb = r.take(ln)
        feats.append(fid)
        if fid == 3:
            session_ok = fb[:4] == magic
        if r.pos > MAX_HANDSHAKE:
            raise ValueError("handshake above maxHandshakeSize")
    if r.pos > MAX_HANDSHAKE:
        raise ValueError("handshake above maxHandshakeSize")
    return ({"agent": agent, "version": ".".join(str(x) for x in ver), "node_name": node_name,
             "declared_address": addr, "features": feats, "session_magic_ok": session_ok, "len": r.pos}, r.pos)


def parse_payload(code, data):
    """The parsed fields of one frame's data (see the module doc); {"parse_error": ...} when it does not parse."""
    r = Reader(data)
    try:
        if code == 65:
            n = r.vlq()
            if n == 0 and r.remaining > 1:
                mode = r.i8()
                if mode != -1:
                    return {"parse_error": f"sync mode {mode}"}
                cnt = r.u8()
                heights = []
                for _ in range(cnt):
                    hb = r.take(r.vlq())
                    try:
                        heights.append(header_height(hb))
                    except (NeedMore, ValueError):
                        heights.append(None)
                return {"sync": "v2", "headers": cnt, "heights": heights}
            r.take(32 * n)
            return {"sync": "v1", "ids": n}
        if code in (55, 22):
            tid, cnt = r.i8(), r.vlq()
            return {"type_id": tid, "count": cnt, "modifier_ids": [r.take(32).hex() for _ in range(cnt)]}
        if code == 33:
            tid, cnt = r.i8(), r.vlq()
            out = {"type_id": tid, "count": cnt}
            ids, hs = [], []
            bts = []
            for _ in range(cnt):
                ids.append(r.take(32).hex())
                mb = r.take(r.vlq())
                if tid == 101:
                    try:
                        hs.append(header_height(mb))
                    except (NeedMore, ValueError):
                        hs.append(None)
                    bts.append(transactions_section_id(ids[-1], header_tx_root(mb)) if len(mb) >= 97 else None)
            out["modifier_ids"] = ids
            if tid == 101:
                out["heights"] = hs
                out["tx_section_ids"] = bts
            return out
        if code == 100:                        # InputBlockAnnouncement
            ver = r.i8()
            ibid, h, _ = header_span(r)
            out = {"version": ver, "input_block_id": ibid, "height": h,
                   "ordering_parent_id": r.last_header[1:33].hex()}
            out["prev_input_block_id"] = r.take(32).hex() if r.u8() else None
            r.take(32 + 32)                    # transactionsDigest, prevTransactionsDigest
            r.take(r.vlq())                    # merkle proof
            if r.u8():                         # weak tx ids carried (Some): the count, then the ids
                n = r.vlq()
                out["weak_tx_ids"] = n
                out["weak_ids"] = [r.take(WEAK_ID_LENGTH).hex() for _ in range(n)]
            else:                              # None: the recipient asks for them (InputBlockTxIds 102)
                out["weak_tx_ids"] = None
            if ver > 1 and r.remaining:        # version 2+: length-prefixed new fields (unparsedBytes)
                ub = r.take(r.u8())
                out["unparsed_len"] = len(ub)
                # the uncles prototype's field (InputBlockUncles.announcementBytes): count, then 32-byte ids
                if ub and ub[0] <= MAX_UNCLES and len(ub) >= 1 + 32 * ub[0]:
                    out["uncle_ids"] = [ub[1 + 32 * i:33 + 32 * i].hex() for i in range(ub[0])]
            return out
        if code in (102, 105):                 # input-block tx ids; request for input-block txs (weak ids)
            ibid, cnt = r.take(32).hex(), r.vlq()
            return {"input_block_id": ibid, "count": cnt,
                    "weak_ids": [r.take(WEAK_ID_LENGTH).hex() for _ in range(cnt)]}
        if code == 104:                        # input-block transactions (bodies not parsed)
            return {"input_block_id": r.take(32).hex(), "count": r.vlq()}
        if code == 106:                        # OrderingBlockAnnouncement (header, then unbroadcast txs, not parsed)
            ver = r.i8()
            hid, h, _ = header_span(r)
            return {"version": ver, "ordering_block_id": hid, "height": h,
                    "tx_section_id": transactions_section_id(hid, header_tx_root(r.last_header)),
                    "non_broadcast_txs": r.vlq()}
        if code == 1:
            return {} if not data else {"parse_error": "GetPeers with data"}
        if code == 2:
            return {"peers": r.vlq()}
        return {}
    except NeedMore:
        return {"parse_error": "short"}
    except ValueError as e:
        return {"parse_error": str(e)}


def checksum(data):
    return hashlib.blake2b(data, digest_size=32).digest()[:4]


# ------------------------------------------------------------------------------------------------ stream -> records
class StreamParser:
    """One direction of one TCP connection, fed in stream order: handshake, then frames, with validated resync."""

    def __init__(self, emit, magic, meta, midstream=False):
        self.emit, self.magic, self.meta = emit, magic, meta
        self.buf = bytearray()
        self.base = 0              # stream offset of buf[0]
        self.ends, self.times = [], []   # stream offset where each fed chunk ends, and its time
        self.state = "resync" if midstream else "handshake"
        self.scan = 0              # resync: buf index to search from
        self.skipped = 0           # resync: bytes passed over in this episode
        self.last_t = None

    def _rec(self, kind, t, **kw):
        d = {"t_ms": t, "kind": kind}
        d.update(self.meta)
        d.update(kw)
        self.emit(d)

    def t_at(self, end_off):
        i = bisect.bisect_left(self.ends, end_off)
        return self.times[min(i, len(self.times) - 1)]

    def _consume(self, n):
        del self.buf[:n]
        self.base += n
        k = bisect.bisect_left(self.ends, self.base)
        if k:   # keep the chunk ending at or after base
            del self.ends[:k]
            del self.times[:k]

    def feed(self, data, t):
        self.buf += data
        self.ends.append(self.base + len(self.buf))
        self.times.append(t)
        self.last_t = t
        self._run()

    def gap(self, t, nbytes):
        """nbytes after the fed bytes were never captured: whatever partial structure is buffered is lost."""
        lost = len(self.buf)
        self._rec("gap", t, bytes=nbytes, lost=lost, at=self.base + lost)
        self.base += lost + nbytes
        self.buf = bytearray()
        self.ends, self.times = [], []
        self.state, self.scan, self.skipped = "resync", 0, 0

    def finish(self, t):
        if self.buf:
            if self.state == "resync":
                self.skipped += len(self.buf)
                self._rec("tail", t, bytes=len(self.buf), unresolved=True)
            else:
                self._rec("tail", t, bytes=len(self.buf))
            self._consume(len(self.buf))

    def _desync(self, why):
        self._rec("desync", self.last_t, why=why, at=self.base)
        self.state, self.scan, self.skipped = "resync", 1, 0

    def _check(self, i, depth=0):
        """A resync candidate at buf[i]: 'ok', 'bad' or 'more' (the buffer ends before it can be judged)."""
        b = self.buf
        if len(b) - i < 9:
            return "more"
        if b[i:i + 4] != self.magic:
            return "bad"
        code = b[i + 4]
        length = struct.unpack(">i", b[i + 5:i + 9])[0]
        if length < 0 or length > MAX_MESSAGE_SIZE:
            return "bad"
        if length > 0:
            if len(b) - i < 13 + length:
                return "more"
            return "ok" if checksum(bytes(b[i + 13:i + 13 + length])) == bytes(b[i + 9:i + 13]) else "bad"
        if code not in CODES or depth >= 4:
            return "bad"
        return self._check(i + 9, depth + 1)

    def _run(self):
        while True:
            b = self.buf
            if self.state == "handshake":
                try:
                    fields, n = parse_handshake(b, self.magic)
                except NeedMore:
                    if len(b) > MAX_HANDSHAKE:
                        self._desync("handshake above maxHandshakeSize")
                        continue
                    return
                except ValueError as e:
                    self._desync(f"handshake: {e}")
                    continue
                self._rec("handshake", self.t_at(self.base + n), **fields)
                self._consume(n)
                self.state = "frames"
            elif self.state == "frames":
                if len(b) < 9:
                    return
                if b[:4] != self.magic:
                    self._desync("magic")
                    continue
                code = b[4]
                length = struct.unpack(">i", b[5:9])[0]
                if length < 0 or length > MAX_MESSAGE_SIZE:
                    self._desync(f"length {length}")
                    continue
                need = 9 if length == 0 else 13 + length
                if len(b) < need:
                    return
                if length:
                    data = bytes(b[13:need])
                    ok = checksum(data) == bytes(b[9:13])
                else:
                    data, ok = b"", None
                rec = {"code": code, "name": CODES.get(code, "unknown"), "len": length, "checksum_ok": ok}
                rec.update(parse_payload(code, data))
                self._rec("frame", self.t_at(self.base + need), **rec)
                self._consume(need)
            else:   # resync
                i = b.find(self.magic, self.scan)
                if i < 0:
                    keep = min(len(b), 3)   # a magic may straddle the next chunk
                    drop = len(b) - keep
                    self.skipped += drop
                    self._consume(drop)
                    self.scan = 0
                    return
                v = self._check(i)
                if v == "more":
                    # a later candidate that validates now wins (real frames do not overlap one that passes)
                    j = b.find(self.magic, i + 1)
                    while j >= 0 and self._check(j) != "ok":
                        j = b.find(self.magic, j + 1)
                    if j < 0:
                        self.scan = i
                        return
                    i, v = j, "ok"
                if v == "bad":
                    self.scan = i + 1
                    continue
                self.skipped += i
                self._rec("resync", self.t_at(self.base + i + 1), skipped=self.skipped)
                self._consume(i)
                self.state, self.scan, self.skipped = "frames", 0, 0


def _signed32(x):
    x &= 0xFFFFFFFF
    return x - (1 << 32) if x & 0x80000000 else x


class Half:
    """One direction of a TCP connection: sequence-ordered delivery to its StreamParser."""

    def __init__(self, parser, isn):
        self.p, self.isn = parser, isn
        self.next = 0          # stream offset expected next
        self.pending = {}      # offset -> (bytes, t)
        self.acked = 0         # highest offset the receiver acknowledged
        self.fin = None        # offset of the FIN, when seen
        self.dups = 0

    def rel(self, seq):
        return self.next + _signed32(seq - (self.isn + self.next))

    def segment(self, seq, data, t):
        off = self.rel(seq)
        end = off + len(data)
        if end <= self.next:
            self.dups += 1
            return
        if off < self.next:
            data, off = data[self.next - off:], self.next
        if off == self.next:
            self.p.feed(data, t)
            self.next = end
            self._drain(t)
        else:
            old = self.pending.get(off)
            if old is None or len(old[0]) < len(data):
                self.pending[off] = (data, t)

    def _drain(self, t_fill):
        # buffered bytes become readable when the hole before them fills: they take the later of the two times
        while self.pending:
            k = min(self.pending)
            data, t = self.pending[k]
            if k > self.next:
                return
            del self.pending[k]
            if k + len(data) > self.next:
                self.p.feed(data[self.next - k:], max(t, t_fill))
                self.next = k + len(data)

    def ack(self, ack_seq, t):
        a = self.rel(ack_seq)
        if self.fin is not None:
            a = min(a, self.fin)
        if a > self.acked:
            self.acked = a
        self._gaps(t, self.acked)

    def _gaps(self, t, upto):
        # bytes before `upto` that were delivered and never captured: declare the gap, jump, keep going
        while self.next < upto:
            later = [k for k in self.pending if k > self.next]
            k = min(later) if later else None
            target = k if k is not None and k <= upto else upto
            self.p.gap(t, target - self.next)
            self.next = target
            self._drain(t)

    def close(self, t):
        while self.pending:
            self._gaps(t, min(self.pending))
        self.p.finish(t)


def parse_packet(pkt, linktype):
    """(kind, fields): kind 'tcp' with {src, dst, sport, dport, seq, ack, flags, payload, truncated}, else 'other'."""
    if linktype == LINKTYPE_ETHERNET:
        if len(pkt) < 14 or struct.unpack("!H", pkt[12:14])[0] != 0x0800:
            return "other", None
        ip = pkt[14:]
    elif linktype == LINKTYPE_RAW:
        ip = pkt
    else:
        return "other", None
    if len(ip) < 20 or ip[0] >> 4 != 4 or ip[9] != 6:
        return "other", None
    ihl = (ip[0] & 0x0F) * 4
    total = struct.unpack("!H", ip[2:4])[0]
    truncated = len(ip) < total
    tcp = ip[ihl:total]
    if len(tcp) < 20:
        return "tcp", {"truncated": True, "headless": True}
    sport, dport, seq, ack = struct.unpack("!HHII", tcp[:12])
    doff = (tcp[12] >> 4) * 4
    flags = tcp[13]
    return "tcp", {"src": socket.inet_ntoa(ip[12:16]), "dst": socket.inet_ntoa(ip[16:20]), "sport": sport,
                   "dport": dport, "seq": seq, "ack": ack, "flags": flags, "payload": bytes(tcp[doff:]),
                   "truncated": truncated, "missing": max(0, total - len(ip))}


FIN, SYN, RST, ACK = 0x01, 0x02, 0x04, 0x10


def read_pcap(path):
    """Yields (t_ms, packet bytes, original length); the link type is in the generator's first yield (None, lt, None)."""
    with open(path, "rb") as fh:
        gh = fh.read(24)
        if len(gh) < 24:
            return
        m = struct.unpack("<I", gh[:4])[0]
        e = "<" if m in (0xA1B2C3D4, 0xA1B23C4D) else ">"
        nano = struct.unpack(e + "I", gh[:4])[0] == 0xA1B23C4D
        yield None, struct.unpack(e + "I", gh[20:24])[0], None
        while True:
            rh = fh.read(16)
            if len(rh) < 16:
                return
            sec, frac, caplen, origlen = struct.unpack(e + "IIII", rh)
            data = fh.read(caplen)
            if len(data) < caplen:
                return   # a record cut by a stop mid-write
            yield sec * 1000 + (frac // 1000000 if nano else frac // 1000), data, origlen


def decode_pcap(path, link, magic, names=None):
    """(records, summary) for one link's pcap."""
    names = names or {}
    recs = []
    summ = {"link": link, "packets": 0, "other": 0, "tcp": 0, "truncated": 0, "conns": 0, "handshakes": 0,
            "frames": 0, "checksum_fail": 0, "desync": 0, "resync": 0, "gap": 0, "gap_bytes": 0, "tail": 0,
            "retransmits": 0, "by_name": {}}
    halves = {}   # (src, sport, dst, dport) -> Half
    conn_of = {}
    closed = set()   # directions ended by FIN or RST: a late retransmit there is not a new stream
    nconn = [0]
    it = read_pcap(path)
    first = next(it, None)
    if first is None:
        return recs, summ
    linktype = first[1]
    last_t = None

    def name(ip):
        return names.get(ip, ip)

    # A direction with no Half (no SYN and no payload captured) can still be seen through the other side's acks: bytes
    # the receiver acknowledged were sent, so if its acks advance, that direction's traffic was lost to the capture.
    unseen = {}   # key -> [first ack, highest ack, time of highest]

    def flush_unseen(key, emit=True):
        u = unseen.pop(key, None)
        if u is None or not emit:
            return
        n = _signed32(u[1] - u[0])
        if n > 1:   # beyond a FIN's one sequence number
            back = (key[2], key[3], key[0], key[1])
            recs.append({"t_ms": u[2], "kind": "gap", "link": link, "conn": conn_of.get(back), "from": name(key[0]),
                         "to": name(key[2]), "bytes": n, "lost": 0, "at": None, "unseen": True})

    def new_half(key, isn, conn, midstream=False):
        flush_unseen(key, emit=midstream)   # a SYN starts a new stream; a midstream half follows unseen bytes
        meta = {"link": link, "conn": conn, "from": name(key[0]), "to": name(key[2])}
        h = Half(StreamParser(recs.append, magic, meta, midstream=midstream), isn)
        halves[key] = h
        conn_of[key] = conn
        return h

    def close(key, t):
        h = halves.pop(key, None)
        if h is not None:
            h.close(t)
            summ["retransmits"] += h.dups
            closed.add(key)

    for t, pkt, _orig in it:
        last_t = t
        summ["packets"] += 1
        kind, p = parse_packet(pkt, linktype)
        if kind == "other":
            summ["other"] += 1
            continue
        summ["tcp"] += 1
        if p.get("truncated"):
            summ["truncated"] += 1
        if p.get("headless"):
            continue
        key = (p["src"], p["sport"], p["dst"], p["dport"])
        rkey = (p["dst"], p["dport"], p["src"], p["sport"])
        fl = p["flags"]
        if fl & SYN:
            closed.discard(key)
            closed.discard(rkey)
            if not fl & ACK:   # a new connection from this side
                flush_unseen(key)
                flush_unseen(rkey)
                close(key, t)
                close(rkey, t)
                nconn[0] += 1
                summ["conns"] += 1
                new_half(key, (p["seq"] + 1) & 0xFFFFFFFF, nconn[0])
            else:              # the answer: same connection as the SYN
                c = conn_of.get(rkey)
                if c is None:
                    nconn[0] += 1
                    summ["conns"] += 1
                    c = nconn[0]
                close(key, t)
                new_half(key, (p["seq"] + 1) & 0xFFFFFFFF, c)
                if rkey not in halves:   # the SYN went uncaptured: its ack is where that direction's bytes start
                    unseen[rkey] = [p["ack"], p["ack"], t]
            continue
        h = halves.get(key)
        payload = p["payload"]
        if h is None and payload and key not in closed:
            c = conn_of.get(rkey)
            if c is None:
                nconn[0] += 1
                summ["conns"] += 1
                c = nconn[0]
            h = new_half(key, p["seq"], c, midstream=True)
        if h is not None and payload:
            h.segment(p["seq"], payload, t)
        if h is not None and fl & FIN:
            h.fin = h.rel(p["seq"]) + len(payload) + p.get("missing", 0)
        if fl & ACK and rkey in halves:
            halves[rkey].ack(p["ack"], t)
        elif fl & ACK and rkey not in closed:
            u = unseen.setdefault(rkey, [p["ack"], p["ack"], t])
            if _signed32(p["ack"] - u[1]) > 0:
                u[1], u[2] = p["ack"], t
        if fl & RST:
            close(key, t)
            close(rkey, t)
        elif h is not None and fl & FIN and h.next >= h.fin:
            close(key, t)
    for key in list(halves):
        close(key, last_t)
    for key in list(unseen):
        flush_unseen(key)
    recs.sort(key=lambda r: r["t_ms"] if r["t_ms"] is not None else 0)
    for r in recs:
        k = r["kind"]
        if k == "frame":
            summ["frames"] += 1
            summ["by_name"][r["name"]] = summ["by_name"].get(r["name"], 0) + 1
            if r["checksum_ok"] is False:
                summ["checksum_fail"] += 1
        elif k == "handshake":
            summ["handshakes"] += 1
        elif k == "gap":
            summ["gap"] += 1
            summ["gap_bytes"] += r["bytes"]
        elif k in ("desync", "resync", "tail"):
            summ[k] += 1
    return recs, summ


def run_names(eff):
    """ip -> node name from effective.json (id_ip per node, a_ip/b_ip per link; written by rig.sh)."""
    out = {}
    for n in eff.get("nodes", []):
        if n.get("id_ip"):
            out[n["id_ip"]] = n["name"]
    for ln in eff.get("links", []):
        if ln.get("a_ip"):
            out[ln["a_ip"]] = ln["a"]
        if ln.get("b_ip"):
            out[ln["b_ip"]] = ln["b"]
    return out


def decode_run(run_dir, magic=None, names=None, out=None):
    eff = {}
    ep = os.path.join(run_dir, "effective.json")
    if os.path.exists(ep):
        with open(ep) as fh:
            eff = json.load(fh)
    if magic is None:
        magic = bytes(eff["magic"]) if eff.get("magic") else DEFAULT_MAGIC
    nm = run_names(eff)
    nm.update(names or {})
    wdir = os.path.join(run_dir, "wire")
    allrecs, summaries = [], []
    for fn in sorted(os.listdir(wdir)):
        if not fn.endswith(".pcap"):
            continue
        link = fn[:-5]
        recs, summ = decode_pcap(os.path.join(wdir, fn), link, magic, nm)
        sp = os.path.join(wdir, link + ".stats.json")
        if os.path.exists(sp):
            with open(sp) as fh:
                st = json.load(fh)
            summ["drops"] = st.get("drops")
            summ["capture_packets"] = st.get("packets")
            summ["drop_seconds"] = [s[0] for s in st.get("series", []) if s[2]]
        else:
            summ["drops"] = None
        allrecs.extend(recs)
        summaries.append(summ)
    allrecs.sort(key=lambda r: r["t_ms"] if r["t_ms"] is not None else 0)
    out = out or os.path.join(run_dir, "messages.jsonl")
    with open(out, "w") as fh:
        for r in allrecs:
            fh.write(json.dumps(r, separators=(",", ":")) + "\n")
    with open(os.path.join(wdir, "summary.json"), "w") as fh:
        json.dump({"magic": magic.hex(), "links": summaries}, fh, indent=1)
    return allrecs, summaries


def summary_line(s):
    top = ", ".join(f"{k} {v}" for k, v in sorted(s["by_name"].items(), key=lambda kv: -kv[1]))
    return (f"{s['link']}: {s['frames']} frames ({top}); conns {s['conns']}, handshakes {s['handshakes']}; "
            f"checksum_fail {s['checksum_fail']}, desync {s['desync']}, gap {s['gap']} ({s['gap_bytes']} B), "
            f"tail {s['tail']}, truncated {s['truncated']}, other {s['other']}; capture drops {s.get('drops')}")


def load_messages(path):
    with open(path) as fh:
        return [json.loads(line) for line in fh if line.strip()]


def main(argv):
    if len(argv) >= 3 and argv[0] == "capture":
        opts = dict(zip(argv[3::2], argv[4::2]))
        rb = opts.get("--rcvbuf")
        return capture(argv[1], argv[2], opts.get("--stats"), int(rb) if rb else None)
    if len(argv) >= 2 and argv[0] == "decode":
        opts = dict(zip(argv[2::2], argv[3::2]))
        magic = bytes.fromhex(opts["--magic"]) if "--magic" in opts else None
        names = dict(kv.split("=", 1) for kv in opts["--names"].split(",")) if "--names" in opts else None
        _, summaries = decode_run(argv[1], magic, names, opts.get("--out"))
        for s in summaries:
            print(summary_line(s))
        return 0
    print(__doc__.strip().splitlines()[3] + "\n" + __doc__.strip().splitlines()[4], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
