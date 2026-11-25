"""Local Antigravity usage dashboard. Python standard library only."""
import json
import re
import sqlite3
import shutil
import tempfile
import webbrowser
from contextlib import closing
from pathlib import Path
from http.server import BaseHTTPRequestHandler, HTTPServer

ROOT = Path.home() / ".gemini/antigravity/conversations"
PORT = 18742
cache = {}


def varint(data, offset):
    value = 0
    for shift in range(0, 70, 7):
        byte = data[offset]
        offset += 1
        value |= (byte & 127) << shift
        if byte < 128:
            return value, offset
    raise ValueError("invalid varint")


def fields(data, wanted):
    view = memoryview(data)
    result = {}
    pos = 0
    while pos < len(view):
        tag, pos = varint(view, pos)
        num, wire = divmod(tag, 8)
        if wire == 0:
            value, pos = varint(view, pos)
        elif wire in (1, 2, 5):
            size = 8 if wire == 1 else 4
            if wire == 2:
                size, pos = varint(view, pos)
            value = view[pos:pos + size]
            pos += size
            if pos > len(view):
                raise ValueError("truncated field")
        else:
            raise ValueError("unsupported wire type")
        if num in wanted:
            result[num] = value
    return result


def read_db(path, *, immutable=False):
    calls = []
    seen = {}
    skipped = 0
    uri = path.as_uri() + ("?mode=ro&immutable=1" if immutable else "?mode=ro")
    with closing(sqlite3.connect(uri, uri=True)) as db:
        db.execute("BEGIN")
        models = {}
        for idx, blob in db.execute("SELECT idx,data FROM gen_metadata WHERE data IS NOT NULL"):
            try:
                inner = fields(fields(blob, {1}).get(1, b""), {19, 21, 22})
                for key in (19, 21, 22):
                    name = bytes(inner.get(key, b"")).decode().strip()
                    if re.fullmatch(r"[A-Za-z0-9_.:/ -]{1,200}", name):
                        models[idx] = name
                        break
            except (UnicodeError, ValueError, TypeError, IndexError):
                continue
        for (blob,) in db.execute("SELECT metadata FROM steps WHERE metadata IS NOT NULL ORDER BY idx"):
            try:
                step = fields(blob, {1, 9, 20})
                if 9 not in step:
                    continue
                usage = fields(step[9], {2, 3, 4, 5, 9, 11})
                tokens = [usage.get(k, 0) for k in (2, 3, 5, 4, 9)]
                if not any(tokens):
                    continue
                stamp = fields(step[1], {1, 2})
                ts = stamp[1] + stamp.get(2, 0) / 1e9
                gen = fields(step.get(20, b""), {3}).get(3, 0)
                row = [ts, models.get(gen, "未识别模型"), *tokens]
                response = bytes(usage.get(11, b""))
                if response and response in seen:
                    calls[seen[response]] = row
                else:
                    if response:
                        seen[response] = len(calls)
                    calls.append(row)
            except (KeyError, TypeError, ValueError, IndexError):
                skipped += 1
    return calls, skipped


def signature(path):
    stat = path.stat()
    wal = Path(str(path) + "-wal")
    try:
        log = wal.stat()
        log_state = (log.st_ino, log.st_size, log.st_mtime_ns)
    except FileNotFoundError:
        log_state = None
    return stat.st_ino, stat.st_size, stat.st_mtime_ns, log_state


def refresh_db(path, before):
    try:
        return read_db(path)
    except sqlite3.OperationalError:
        # A closed WAL-mode DB can lack its sidecars. Read a private, stable
        # copy so SQLite can initialize sidecars without touching the source.
        journal = Path(str(path) + "-journal")
        if before[-1] is not None or journal.exists():
            raise
        with tempfile.TemporaryDirectory() as folder:
            copy = Path(folder) / "snapshot.db"
            shutil.copyfile(path, copy)
            if signature(path) != before or journal.exists():
                raise sqlite3.OperationalError("会话库正在更新")
            return read_db(copy, immutable=True)


def snapshot():
    rows, issues = [], []
    paths = set(ROOT.glob("*.db"))
    for old in cache.keys() - paths:
        del cache[old]
    for path in paths:
        try:
            current = signature(path)
            if path not in cache or cache[path][0] != current:
                calls, skipped = refresh_db(path, current)
                cache[path] = current, calls, skipped
        except (OSError, sqlite3.Error) as error:
            issues.append(f"{path.stem} 读取失败：{error}")
        if path in cache:
            rows.extend(row + [path.stem] for row in cache[path][1])
            if cache[path][2]:
                issues.append(f"{cache[path][2]} 条记录解析失败")
        else:
            issues.append("用量数据不完整")
    titles = {}
    summary = ROOT.parent / "conversation_summaries.db"
    if summary.exists():
        # WAL 模式下只读打开偶尔会失败（unable to open database file），先重试再退化为 immutable 读快照
        for suffix in ("?mode=ro", "?mode=ro", "?mode=ro&immutable=1"):
            try:
                with closing(sqlite3.connect(summary.as_uri() + suffix, uri=True)) as db:
                    titles = dict(db.execute("SELECT conversation_id, title FROM conversation_summaries"))
                break
            except sqlite3.Error:
                continue
        else:
            issues.append("部分线程标题暂时无法读取")
    return dict(rows=rows, titles=titles, databases=len(paths), issues=issues)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.headers.get("Host") not in (f"127.0.0.1:{PORT}", f"localhost:{PORT}"):
            return self.send_error(403)
        if self.path == "/":
            data = Path(__file__).with_name("index.html").read_bytes()
            mime = "text/html"
        elif self.path == "/usage.json":
            data = json.dumps(snapshot()).encode()
            mime = "application/json"
        else:
            return self.send_error(404)
        self.send_response(200)
        self.send_header("Content-Type", mime + "; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    with HTTPServer(("127.0.0.1", PORT), Handler) as server:
        if "--quiet" not in __import__("sys").argv:
            webbrowser.open(f"http://127.0.0.1:{PORT}/")
        server.serve_forever()
