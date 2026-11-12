#!/usr/bin/env python3
"""Register N wallet scans over one keep-alive HTTP connection (scan-upgrade's filler phase).

  scan-upgrade-fill.py <host> <port> <api_key> <count>

Every scan has a rule that matches no box (R1 equals the one-byte collection 0xff). Prints one JSON line:
{"registered": n, "first": id, "last": id, "seconds": s, "errors": e, "last_error": "..."}.
"""
import http.client
import json
import sys
import time

host, port, key, count = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
body_tpl = '{"scanName":"su-fill-%d","walletInteraction":"off","removeOffchain":true,' \
           '"trackingRule":{"predicate":"equals","register":"R1","value":"0e01ff"}}'
hdr = {"api_key": key, "Content-Type": "application/json"}
conn = http.client.HTTPConnection(host, port, timeout=60)
first = last = None
errors = 0
last_error = ""
t0 = time.time()
n = 0
for i in range(count):
    for attempt in range(3):
        try:
            conn.request("POST", "/scan/register", body_tpl % i, hdr)
            resp = conn.getresponse()
            data = resp.read()
            break
        except (http.client.HTTPException, OSError) as e:
            last_error = repr(e)[:200]
            conn.close()
            conn = http.client.HTTPConnection(host, port, timeout=60)
            time.sleep(1)
    else:
        errors += 1
        continue
    try:
        sid = json.loads(data)["scanId"]
    except (ValueError, KeyError, TypeError):
        errors += 1
        last_error = data[:200].decode("utf-8", "replace")
        continue
    if first is None:
        first = sid
    last = sid
    n += 1
print(json.dumps({"registered": n, "first": first, "last": last, "seconds": round(time.time() - t0, 1),
                  "errors": errors, "last_error": last_error}))
