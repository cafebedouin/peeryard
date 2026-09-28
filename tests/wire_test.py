"""Unit tests for diag/wire.py on synthetic byte streams built here: TCP reassembly (split, coalesced, retransmitted,
out-of-order, gap), framing (checksum, validated resync, length bound, tail), the unframed handshake, the six
parsers, and packets that are not IPv4 TCP. Run: python3 -m unittest tests/wire_test.py"""
import hashlib
import json
import os
import socket
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "diag"))
import wire  # noqa: E402

MAGIC = bytes([112, 101, 101, 114])
A, B = "100.64.0.1", "100.64.0.2"
NAMES = {A: "A", B: "B"}
FIN, SYN, RST, ACK, PSH = 0x01, 0x02, 0x04, 0x10, 0x08


def vlq(v):
    out = bytearray()
    while True:
        c = v & 0x7F
        v >>= 7
        if v:
            out.append(c | 0x80)
        else:
            out.append(c)
            return bytes(out)


def frame(code, data, magic=MAGIC, bad_checksum=False):
    if not data:
        return magic + bytes([code]) + struct.pack(">i", 0)
    ck = hashlib.blake2b(data, digest_size=32).digest()[:4]
    if bad_checksum:
        ck = bytes([ck[0] ^ 0xFF]) + ck[1:]
    return magic + bytes([code]) + struct.pack(">i", len(data)) + ck + data


def header(height, ts=1790000000000):
    # HeaderSerializer v6.0.6: version, parentId, ADProofsRoot, transactionsRoot, stateRoot, timestamp, extensionRoot,
    # nBits, height, votes, unparsed-length byte (version > 1), then the PoW solution
    return (bytes([2]) + b"\x11" * 32 + b"\x22" * 32 + b"\x33" * 32 + b"\x44" * 33 + vlq(ts) + b"\x55" * 32
            + b"\x01\x02\x03\x04" + vlq(height) + b"\x00\x00\x00" + b"\x00" + b"\x66" * 33 + b"\x77" * 8)


def sync_v2(heights):
    body = vlq(0) + b"\xff" + bytes([len(heights)])
    for h in heights:
        hb = header(h)
        body += vlq(len(hb)) + hb
    return frame(65, body)


def handshake(agent="ergoref", name="nodeA", magic=MAGIC, addr=None):
    feats = [(3, magic + struct.pack(">q", -12345)), (16, b"\x00\x01\x02\x03")]
    b = vlq(1790000000123) + bytes([len(agent)]) + agent.encode() + bytes([6, 0, 6]) + bytes([len(name)]) + name.encode()
    if addr:
        ip, port = addr
        b += b"\x01" + bytes([8]) + socket.inet_aton(ip) + vlq(port)
    else:
        b += b"\x00"
    b += bytes([len(feats)])
    for fid, fb in feats:
        b += bytes([fid]) + vlq(len(fb)) + fb
    return b


def packet(src, dst, sport, dport, seq, ack, flags, payload=b"", cut=0, ethertype=0x0800):
    tcp = struct.pack("!HHIIBBHHH", sport, dport, seq & 0xFFFFFFFF, ack & 0xFFFFFFFF, 5 << 4, flags, 65535, 0, 0)
    tcp += payload
    ip = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + len(tcp), 0, 0, 64, 6, 0, socket.inet_aton(src),
                     socket.inet_aton(dst)) + tcp
    if cut:
        ip = ip[:-cut]
    return b"\x02" * 6 + b"\x04" * 6 + struct.pack("!H", ethertype) + ip


class Wire:
    """A pcap of one link: A (port 40000) dials B (port 9021)."""

    def __init__(self, isn_a=1000, isn_b=0xFFFFFF00):
        self.recs = []
        self.t = 1790000000.000
        self.isn = {A: isn_a, B: isn_b}
        self.port = {A: 40000, B: 9021}
        self.off = {A: 0, B: 0}

    def _other(self, s):
        return B if s == A else A

    def raw(self, pkt, dt=0.001):
        self.t += dt
        self.recs.append((self.t, pkt))

    def open(self):
        pa, pb = self.port[A], self.port[B]
        self.raw(packet(A, B, pa, pb, self.isn[A], 0, SYN))
        self.raw(packet(B, A, pb, pa, self.isn[B], self.isn[A] + 1, SYN | ACK))
        self.raw(packet(A, B, pa, pb, self.isn[A] + 1, self.isn[B] + 1, ACK))
        return self

    def seg(self, src, off, data, cut=0, flags=ACK | PSH):
        dst = self._other(src)
        self.raw(packet(src, dst, self.port[src], self.port[dst], self.isn[src] + 1 + off,
                        self.isn[dst] + 1 + self.off[dst], flags, data, cut=cut))
        return self.t

    def send(self, src, data):
        t = self.seg(src, self.off[src], data)
        self.off[src] += len(data)
        return t

    def skip(self, src, data):
        """data crossed the link but was not captured"""
        self.off[src] += len(data)

    def ack(self, src, upto=None):
        dst = self._other(src)
        self.raw(packet(src, dst, self.port[src], self.port[dst], self.isn[src] + 1 + self.off[src],
                        self.isn[dst] + 1 + (self.off[dst] if upto is None else upto), ACK))

    def pcap(self, d):
        p = os.path.join(d, "A-B.pcap")
        with open(p, "wb") as fh:
            fh.write(wire.pcap_header())
            for t, pk in self.recs:
                fh.write(wire.pcap_record(t, pk))
        return p


def ms(t):
    """the pcap record's time in epoch ms, as written (usec rounded) and read (usec // 1000)"""
    sec, usec = wire.pcap_ts(t)
    return sec * 1000 + usec // 1000


def decode(w):
    with tempfile.TemporaryDirectory() as d:
        return wire.decode_pcap(w.pcap(d), "A-B", MAGIC, NAMES)


def frames(recs, frm=None):
    return [r for r in recs if r["kind"] == "frame" and (frm is None or r["from"] == frm)]


def kinds(recs):
    return [r["kind"] for r in recs]


class Reassembly(unittest.TestCase):
    def test_frame_split_across_three_segments(self):
        w = Wire().open()
        w.send(A, handshake())
        f = sync_v2([7, 6])
        w.send(A, f[:5])
        w.send(A, f[5:40])
        t3 = w.send(A, f[40:])
        recs, s = decode(w)
        fr = frames(recs)
        self.assertEqual(len(fr), 1)
        self.assertEqual((fr[0]["code"], fr[0]["checksum_ok"], fr[0]["heights"]), (65, True, [7, 6]))
        self.assertEqual(fr[0]["t_ms"], ms(t3))   # the completing segment's time
        self.assertEqual((s["desync"], s["gap"], s["tail"]), (0, 0, 0))

    def test_two_frames_in_one_segment(self):
        w = Wire().open()
        w.send(A, handshake() + frame(1, b"") + frame(55, bytes([101]) + vlq(1) + b"\x09" * 32))
        recs, s = decode(w)
        self.assertEqual([(r["name"], r["checksum_ok"]) for r in frames(recs)], [("GetPeers", None), ("Inv", True)])
        self.assertEqual(s["desync"], 0)

    def test_retransmitted_segment(self):
        w = Wire().open()
        hs = handshake()
        w.send(A, hs)
        f = sync_v2([3])
        o = w.off[A]
        w.send(A, f[:20])
        w.seg(A, o, f[:20])          # the same bytes again
        w.seg(A, o + 10, f[10:30])   # an overlapping retransmit
        w.send(A, f[20:])
        recs, s = decode(w)
        self.assertEqual([r["heights"] for r in frames(recs)], [[3]])
        self.assertEqual((s["desync"], s["gap"]), (0, 0))

    def test_out_of_order_pair(self):
        w = Wire().open()
        w.send(A, handshake())
        f = sync_v2([9])
        o = w.off[A]
        w.seg(A, o + 30, f[30:])
        t = w.seg(A, o, f[:30])
        w.off[A] += len(f)
        recs, s = decode(w)
        fr = frames(recs)
        self.assertEqual([r["heights"] for r in fr], [[9]])
        self.assertEqual(fr[0]["t_ms"], ms(t))
        self.assertEqual((s["desync"], s["gap"]), (0, 0))

    def test_sequence_wraps_past_2_32(self):
        w = Wire(isn_b=0xFFFFFFF0).open()   # B's stream crosses 2^32 inside its handshake
        w.send(B, handshake(name="nodeB"))
        w.send(B, frame(2, vlq(4)))
        recs, s = decode(w)
        self.assertEqual([r["peers"] for r in frames(recs, "B")], [4])
        self.assertEqual(s["desync"], 0)

    def test_gap_declared_by_ack_then_resync(self):
        w = Wire().open()
        w.send(A, handshake())
        w.send(A, frame(55, bytes([101]) + vlq(1) + b"\x01" * 32))
        w.skip(A, frame(55, bytes([101]) + vlq(1) + b"\x02" * 32))   # delivered, not captured
        w.send(A, frame(22, bytes([102]) + vlq(2) + b"\x03" * 64))
        w.ack(B)   # B acknowledges everything: the hole is a capture gap
        recs, s = decode(w)
        self.assertEqual([r["name"] for r in frames(recs)], ["Inv", "RequestModifier"])
        self.assertEqual((s["gap"], s["gap_bytes"]), (1, 9 + 4 + 34))
        self.assertIn("resync", kinds(recs))

    def test_hole_filled_by_retransmission_is_no_gap(self):
        w = Wire().open()
        w.send(A, handshake())
        f1 = frame(55, bytes([101]) + vlq(1) + b"\x01" * 32)
        o = w.off[A]
        w.skip(A, f1)                     # lost on the wire (netem), so not acknowledged
        w.send(A, frame(1, b""))
        w.ack(B, upto=o)                  # B has everything before the hole
        w.seg(A, o, f1)                   # the retransmission fills it
        w.ack(B)
        recs, s = decode(w)
        self.assertEqual([r["name"] for r in frames(recs)], ["Inv", "GetPeers"])
        self.assertEqual(s["gap"], 0)

    def test_truncated_packet_counted_and_its_hole_is_a_gap(self):
        w = Wire().open()
        w.send(A, handshake())
        f = frame(55, bytes([101]) + vlq(1) + b"\x01" * 32)
        w.seg(A, w.off[A], f, cut=10)     # the capture kept all but the last 10 bytes
        w.off[A] += len(f)
        # a length-0 frame alone cannot be validated after a gap (no checksum): it is accepted with the frame after it
        w.send(A, frame(1, b"") + frame(2, vlq(1)))
        w.ack(B)
        recs, s = decode(w)
        self.assertEqual(s["truncated"], 1)
        self.assertEqual(s["gap"], 1)
        self.assertEqual([r["name"] for r in frames(recs)], ["GetPeers", "Peers"])

    def test_reconnect_gets_a_new_conn(self):
        w = Wire().open()
        w.send(A, handshake())
        w.raw(packet(A, B, 40000, 9021, w.isn[A] + 1 + w.off[A], 0, RST))
        w2 = Wire(isn_a=777, isn_b=888)
        w2.t = w.t
        w2.port[A] = 40001
        w2.open()
        w2.send(A, handshake())
        w.recs += w2.recs
        recs, s = decode(w)
        self.assertEqual(s["conns"], 2)
        self.assertEqual(sorted(r["conn"] for r in recs if r["kind"] == "handshake"), [1, 2])


class Framing(unittest.TestCase):
    def test_bad_checksum_flagged_and_decoding_continues(self):
        w = Wire().open()
        w.send(A, handshake())
        w.send(A, frame(55, bytes([2]) + vlq(1) + b"\x01" * 32, bad_checksum=True) + frame(1, b""))
        recs, s = decode(w)
        self.assertEqual([(r["name"], r["checksum_ok"]) for r in frames(recs)], [("Inv", False), ("GetPeers", None)])
        self.assertEqual((s["checksum_fail"], s["desync"]), (1, 0))

    def test_handshake_contains_magic_and_first_frame_is_at_its_parsed_end(self):
        w = Wire().open()
        hs_a, hs_b = handshake(), handshake(agent="ergoref", name="nodeB", addr=("100.64.0.2", 9021))
        self.assertIn(MAGIC, hs_a)   # the session-id feature carries the magic
        w.send(A, hs_a + frame(65, vlq(0) + b"\xff" + b"\x00"))
        w.send(B, hs_b)
        w.send(B, frame(1, b""))
        recs, s = decode(w)
        hs = [r for r in recs if r["kind"] == "handshake"]
        self.assertEqual([(h["from"], h["agent"], h["version"], h["node_name"], h["len"], h["session_magic_ok"])
                          for h in hs],
                         [("A", "ergoref", "6.0.6", "nodeA", len(hs_a), True),
                          ("B", "ergoref", "6.0.6", "nodeB", len(hs_b), True)])
        self.assertEqual(hs[0]["features"], [3, 16])
        self.assertEqual(hs[1]["declared_address"], "100.64.0.2:9021")
        self.assertEqual([(r["from"], r["name"]) for r in frames(recs)], [("A", "SyncInfo"), ("B", "GetPeers")])
        self.assertFalse(any(r["code"] == 75 for r in frames(recs)))
        self.assertEqual((s["desync"], s["handshakes"]), (0, 2))

    def test_false_magic_in_payload_refused_on_resync(self):
        w = Wire().open()
        w.send(A, handshake())
        # a frame whose data holds the magic and a plausible header (code 65, length 5, no valid checksum)
        trap = MAGIC + bytes([65]) + struct.pack(">i", 5) + b"\x00\x00\x00\x00" + b"\x00\xff\x00\x00\x00"
        f1 = frame(33, bytes([2]) + vlq(1) + b"\x05" * 32 + vlq(len(trap) + 4) + b"\x00" * 4 + trap)
        cut = 12
        w.skip(A, f1[:cut])     # the resync starts inside f1, before the trap
        w.send(A, f1[cut:])
        w.send(A, frame(55, bytes([101]) + vlq(1) + b"\x06" * 32))
        w.ack(B)
        recs, s = decode(w)
        self.assertEqual([r["name"] for r in frames(recs)], ["Inv"])   # neither f1's tail nor the trap
        self.assertEqual((s["gap"], s["checksum_fail"]), (1, 0))

    def test_length_above_max_is_desync_at_once(self):
        w = Wire().open()
        w.send(A, handshake())
        w.send(A, MAGIC + bytes([33]) + struct.pack(">i", wire.MAX_MESSAGE_SIZE + 1) + b"\x00" * 4)
        w.send(A, frame(1, b"") + frame(2, vlq(1)))
        recs, s = decode(w)
        d = [r for r in recs if r["kind"] == "desync"]
        self.assertEqual(len(d), 1)
        self.assertIn("length", d[0]["why"])
        # the refused header does not make the decoder wait for 16 MB: the next frames are decoded
        self.assertEqual([r["name"] for r in frames(recs)], ["GetPeers", "Peers"])
        self.assertEqual(s["tail"], 0)

    def test_partial_frame_at_stop_is_tail_not_desync(self):
        w = Wire().open()
        w.send(A, handshake())
        f = sync_v2([5])
        w.send(A, f[:25])
        recs, s = decode(w)
        self.assertEqual((s["tail"], s["desync"], s["frames"]), (1, 0, 0))
        self.assertEqual([r["bytes"] for r in recs if r["kind"] == "tail"], [25])

    def test_non_tcp_counted_other(self):
        w = Wire().open()
        w.raw(b"\xff" * 6 + b"\x02" * 6 + b"\x08\x06" + b"\x00" * 28)                  # ARP
        w.raw(b"\x33" * 6 + b"\x02" * 6 + b"\x86\xdd" + b"\x60" + b"\x00" * 39)        # IPv6
        w.send(A, handshake())
        recs, s = decode(w)
        self.assertEqual(s["other"], 2)
        self.assertEqual(kinds(recs), ["handshake"])


class Parsers(unittest.TestCase):
    def one(self, fr):
        w = Wire().open()
        w.send(A, handshake())
        w.send(A, fr)
        recs, _ = decode(w)
        (r,) = frames(recs)
        return r

    def test_header_height(self):
        for h in (0, 1, 127, 128, 1876543):
            self.assertEqual(wire.header_height(header(h)), h)

    def test_syncinfo_v1(self):
        r = self.one(frame(65, vlq(3) + b"\x01" * 96))
        self.assertEqual((r["sync"], r["ids"]), ("v1", 3))

    def test_syncinfo_v2(self):
        r = self.one(sync_v2([200, 199, 190]))
        self.assertEqual((r["sync"], r["headers"], r["heights"]), ("v2", 3, [200, 199, 190]))

    def test_inv(self):
        r = self.one(frame(55, bytes([101]) + vlq(3) + b"\x01" * 96))
        self.assertEqual((r["name"], r["type_id"], r["count"]), ("Inv", 101, 3))

    def test_request_modifier(self):
        r = self.one(frame(22, bytes([102]) + vlq(2) + b"\x01" * 64))
        self.assertEqual((r["name"], r["type_id"], r["count"]), ("RequestModifier", 102, 2))

    def test_modifiers_headers(self):
        body = bytes([101]) + vlq(2)
        for h in (41, 42):
            hb = header(h)
            body += b"\x09" * 32 + vlq(len(hb)) + hb
        r = self.one(frame(33, body))
        self.assertEqual((r["name"], r["type_id"], r["count"], r["heights"]), ("Modifiers", 101, 2, [41, 42]))

    def test_modifiers_transactions_have_no_heights(self):
        r = self.one(frame(33, bytes([2]) + vlq(1) + b"\x09" * 32 + vlq(3) + b"abc"))
        self.assertEqual((r["type_id"], r["count"]), (2, 1))
        self.assertNotIn("heights", r)

    def test_get_peers(self):
        r = self.one(frame(1, b""))
        self.assertEqual((r["name"], r["len"], r["checksum_ok"]), ("GetPeers", 0, None))

    def test_peers(self):
        r = self.one(frame(2, vlq(2) + b"\x00" * 10))
        self.assertEqual((r["name"], r["peers"]), ("Peers", 2))

    def test_other_code_is_code_and_len_only(self):
        r = self.one(frame(90, b"\x01\x02"))
        self.assertEqual((r["code"], r["name"], r["len"]), (90, "GetNipopowProof", 2))
        self.assertFalse({"type_id", "count", "sync"} & set(r))


class Pcap(unittest.TestCase):
    def test_record_time_is_epoch_ms(self):
        w = Wire().open()
        t = w.send(A, handshake())
        with tempfile.TemporaryDirectory() as d:
            p = w.pcap(d)
            it = wire.read_pcap(p)
            self.assertEqual(next(it)[1], wire.LINKTYPE_ETHERNET)
            ts = [x[0] for x in it]
        self.assertEqual(ts[-1], ms(t))

    def test_decode_run_uses_effective_magic_and_names(self):
        w = Wire().open()
        w.send(A, handshake(magic=bytes([7, 7, 7, 7])))
        w.send(A, frame(1, b"", magic=bytes([7, 7, 7, 7])))
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(os.path.join(d, "wire"))
            w.pcap(os.path.join(d, "wire"))
            with open(os.path.join(d, "effective.json"), "w") as fh:
                fh.write('{"magic": [7,7,7,7], "nodes": [{"name": "A", "id_ip": "%s"}, {"name": "B", "id_ip": "%s"}],'
                         ' "links": [{"a": "A", "b": "B"}]}' % (A, B))
            recs, summ = wire.decode_run(d)
            self.assertTrue(os.path.exists(os.path.join(d, "messages.jsonl")))
            self.assertEqual(len(wire.load_messages(os.path.join(d, "messages.jsonl"))), len(recs))
        self.assertEqual([(r["from"], r["to"], r["name"]) for r in frames(recs)], [("A", "B", "GetPeers")])
        self.assertEqual(summ[0]["drops"], None)   # no stats file: unknown, not zero



class Golden(unittest.TestCase):
    """The first seconds of a real two-node bringup (tests/fixtures/wire-bringup.*): its decode must not drift."""

    def test_real_capture_decodes_to_the_recorded_digest(self):
        fx = os.path.join(os.path.dirname(__file__), "fixtures")
        with open(os.path.join(fx, "wire-bringup.json")) as fh:
            meta = json.load(fh)
        recs, summ = wire.decode_pcap(os.path.join(fx, "wire-bringup.pcap"), "A-B", bytes(meta["magic"]), meta["names"])
        got = {k: v for k, v in summ.items() if k != "link"}
        self.assertEqual(got, meta["expected"]["summary"])
        self.assertEqual(len(recs), meta["expected"]["records"])
        digest = hashlib.sha256(json.dumps(recs, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        self.assertEqual(digest, meta["expected"]["sha256"])
        hs = [r for r in recs if r["kind"] == "handshake"]
        self.assertEqual(sorted((h["from"], h["agent"], h["version"], h["session_magic_ok"]) for h in hs),
                         [("A", "ergoref", meta["node"]["version"], True), ("B", "ergoref", meta["node"]["version"], True)])


if __name__ == "__main__":
    unittest.main()
