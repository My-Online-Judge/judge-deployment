"""Reads a .env file the way `docker compose` does, so a value becomes the same Secret value the compose stack read: an optional
`export `, the key, `=`, then a value that is single-quoted (literal), double-quoted (backslash escapes) or bare (trimmed, an inline
` # comment` dropped). Blank lines and `#` lines are skipped. tests/k3s-dotenv.test.sh asks compose itself for the expected values."""
import re

_ESCAPES = {"n": "\n", "r": "\r", "t": "\t", '"': '"', "\\": "\\", "$": "$"}


def _value(raw):
    raw = raw.strip()
    if raw[:1] == "'":
        end = raw.find("'", 1)
        return raw[1:end] if end != -1 else raw[1:]
    if raw[:1] == '"':
        out, i = [], 1
        while i < len(raw) and raw[i] != '"':
            if raw[i] == "\\" and i + 1 < len(raw):
                out.append(_ESCAPES.get(raw[i + 1], "\\" + raw[i + 1]))
                i += 2
            else:
                out.append(raw[i])
                i += 1
        return "".join(out)
    return re.split(r"\s#", raw, maxsplit=1)[0].rstrip()


def parse(path):
    """{key: value} of a .env file."""
    values = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\r\n")
            if not line.strip() or line.lstrip().startswith("#") or "=" not in line:
                continue
            key, _, raw = line.partition("=")
            key = re.sub(r"^\s*export\s+", "", key).strip()
            values[key] = _value(raw)
    return values
