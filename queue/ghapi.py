"""ghapi.py: the GitHub REST client the queue builder uses (public data; GITHUB_TOKEN only raises the rate limit), and
the time helpers its timestamps need. Part of queue/build.py (see its docstring)."""
import datetime as dt, json, sys, time, urllib.error, urllib.parse, urllib.request


API = "https://api.github.com"


def now_utc():
    return dt.datetime.now(dt.timezone.utc)


def parse_ts(s):
    return dt.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)


def api(path, params=None, token=None, paginate=False):
    url = API + path + ("?" + urllib.parse.urlencode(params) if params else "")
    out = []
    while url:
        req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json",
                                                   "User-Agent": "peeryard-queue",
                                                   **({"Authorization": f"Bearer {token}"} if token else {})})
        for attempt in range(4):
            try:
                with urllib.request.urlopen(req, timeout=60) as r:
                    data = json.loads(r.read().decode())
                    link = r.headers.get("Link", "")
                    break
            except urllib.error.HTTPError as e:
                if (e.code in (403, 429) or 500 <= e.code < 600) and attempt < 3:   # rate limit, or a passing GitHub 5xx
                    time.sleep(30 * (attempt + 1)); continue
                raise
        if not paginate:
            return data
        out.extend(data)
        url = None
        for part in link.split(","):
            if 'rel="next"' in part:
                url = part.split(";")[0].strip().strip("<>")
    return out



def search_numbers(q, token, per_page=100):
    """The issue/pull-request numbers a search query finds, every page: the search API answers with an object
    ({total_count, items}), not a list, so api(paginate=True) cannot page it; pages are read with page= until a short
    one (the API serves at most 1000 results). A failed query is reported on stderr and counts what was read before it."""
    nums, page = set(), 1
    while True:
        try:
            res = api("/search/issues", {"q": q, "per_page": per_page, "page": page}, token)
        except Exception as e:
            print(f"warning: search failed on page {page}, outcomes may be incomplete: {q!r}: {str(e)[:200]}", file=sys.stderr)
            break
        items = res.get("items") or []
        nums.update(it["number"] for it in items)
        if res.get("incomplete_results"):
            print(f"warning: GitHub marked the search results incomplete: {q!r}", file=sys.stderr)
        if len(items) < per_page or page * per_page >= 1000:
            break
        page += 1
    return nums
