#!/usr/bin/env python3
# appkit-proxy.py: an HTTP forwarder in front of a devnet Ergo node for clients built on ergo-appkit.
#
# appkit maps a node's /info "network" to its NetworkType enum, which has only mainnet and testnet, and refuses a node
# that reports "devnet". This forwarder rewrites that one field to "testnet" (the devnet uses testnet address prefixes,
# so everything else lines up) and passes every other request through byte for byte, headers included.
#
#   appkit-proxy.py --listen 127.0.0.1:9153 --upstream http://127.0.0.1:9052 [--record-checks FILE] [--mirror]
#
#   --record-checks FILE  append every body POSTed to /transactions/check as one JSON line (what the client built)
#   --mirror              a transaction the node's check accepts is POSTed to /transactions at once, inside the same
#                         height, so the node's own miner can mine what a block-building client would have carried
#                         in its own candidate (the node must run with ergo.node.minimalFeeAmount = 0 for a fee-less one)
#
# Experiment tooling for a devnet, stdlib only. Never put it in front of a mainnet node.
import argparse, http.server, json, sys, urllib.request, urllib.error

ap = argparse.ArgumentParser()
ap.add_argument("--listen", default="127.0.0.1:9153"); ap.add_argument("--upstream", default="http://127.0.0.1:9052")
ap.add_argument("--record-checks", default=""); ap.add_argument("--mirror", action="store_true")
A = ap.parse_args(); UP = A.upstream.rstrip("/")

def log(line): sys.stderr.write(line + "\n"); sys.stderr.flush()

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def forward(self):
        n = int(self.headers.get("Content-Length") or 0); body = self.rfile.read(n) if n else None
        path = self.path.split("?")[0]
        req = urllib.request.Request(UP + self.path, data=body, method=self.command)
        for k, v in self.headers.items():
            if k.lower() not in ("host", "content-length", "connection"): req.add_header(k, v)
        try:
            r = urllib.request.urlopen(req, timeout=120); status, data, hdrs = r.status, r.read(), r.headers
        except urllib.error.HTTPError as e:
            status, data, hdrs = e.code, e.read(), e.headers
        if path == "/transactions/check" and body:
            if A.record_checks:
                with open(A.record_checks, "ab") as f: f.write(body + b"\n")
            if A.mirror and status == 200:
                try:
                    r2 = urllib.request.urlopen(urllib.request.Request(UP + "/transactions", data=body, method="POST",
                        headers={"Content-Type": "application/json"}), timeout=60)
                    log("mirrored to mempool: " + r2.read().decode()[:80])
                except urllib.error.HTTPError as e:
                    log("mirror refused: " + e.read().decode()[:200])
        if path == "/info" and status == 200:
            try:
                j = json.loads(data)
                if j.get("network") == "devnet": j["network"] = "testnet"; data = json.dumps(j).encode()
            except Exception: pass
        self.send_response(status)
        self.send_header("Content-Type", hdrs.get("Content-Type") or "application/json")
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    do_GET = do_POST = do_PUT = do_DELETE = forward
    def log_message(self, *a): pass

host, port = A.listen.rsplit(":", 1)
log("appkit-proxy: %s -> %s%s%s" % (A.listen, UP, " recording checks to " + A.record_checks if A.record_checks else "", " mirroring" if A.mirror else ""))
http.server.ThreadingHTTPServer((host, int(port)), Handler).serve_forever()
