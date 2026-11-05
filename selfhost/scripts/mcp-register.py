#!/usr/bin/env python3
"""Register the live browser bridge and the vault MCP server with every harness.

Use through make (selfhost/Makefile):
  make mcp-register          add the servers where they are missing
  make mcp-unregister        remove what mcp-register added (and only that)
  make mcp-register DRY=1    say what would change, write nothing

Servers:
  happy-browser-bridge  node selfhost/browser/bridge/mcp.mjs (reads its tokens
                        from their own files; no token is written anywhere)
  vault                 node selfhost/vault-mcp/mcp.mjs, only if that file exists

Files (each one that exists, or that its harness reads, is edited in place):
  ~/.codex/config.toml                              [mcp_servers.<name>], env_vars forwards HAPPY_SESSION_ID
                                                    and HAPPY_FORKED_FROM_SESSION_ID
  ~/.config/opencode/opencode.json                  "mcp": {type local, command [...]}
  ~/.gemini/settings.json                           "mcpServers" (Gemini CLI)
  ~/.gemini/config/mcp_config.json                  "mcpServers" (Antigravity / agy)
  ~/.claude.json                                    top-level "mcpServers", stdio
  ~/.local/share/happy-agent/happy/config/mcp.toml  [mcp_servers.<name>] (container paths)
  prep-pro:~/.gemini/antigravity/mcp_config.json    over `ssh prep-ml`, only if prep-pro
                                                    reaches prep-ml without a password

Before a file is changed its original is copied to
/home/prep/happy/trash/<ts>_mcp-configs/. Everything else in each file is kept.
An entry already pointing at the same server script, under any name, is left
alone. What was added is recorded in ~/.local/share/happy-mcp-register/state.json
so that unregister removes only that. In an entry recorded there (and only
there), names missing from its env_vars list are added on the next register.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
REPO = "/home/prep/happy"
TRASH = os.environ.get("HAPPY_MCP_REGISTER_TRASH") or os.path.join(REPO, "trash")
BRIDGE = os.path.join(REPO, "selfhost/browser/bridge/mcp.mjs")
VAULT = os.path.join(REPO, "selfhost/vault-mcp/mcp.mjs")
STATE = os.path.join(HOME, ".local/share/happy-mcp-register/state.json")
HOST_NODE = shutil.which("node") or "/usr/bin/node"
# The happy-agent container mounts the host's node here (selfhost/browser/README.md).
AGENT_NODE = "/usr/local/bin/node"
# Harnesses with a tool time limit: browser_wait_for_human returns inside it.
WAIT = {"BRIDGE_WAIT_MAX_S": "570"}
REMOTE_HOST = "prep-pro"
REMOTE_HOP = "prep-ml"
REMOTE_FILE = "~/.gemini/antigravity/mcp_config.json"

MARK_BEGIN = "# >>> happy mcp-register: {name}"
MARK_END = "# <<< happy mcp-register: {name}"


def servers():
    """(name, script, extra env for harnesses with a tool time limit)."""
    out = [("happy-browser-bridge", BRIDGE, WAIT)]
    if os.path.isfile(VAULT):
        out.append(("vault", VAULT, {}))
    return out


# ---------------------------------------------------------------- state

def load_state():
    try:
        with open(STATE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_state(state, dry):
    if dry:
        return
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, STATE)


# ---------------------------------------------------------------- backup / write

class Backup:
    def __init__(self, dry):
        self.dry = dry
        self.dir = None

    def folder(self):
        if self.dir is None:
            self.dir = os.path.join(TRASH, time.strftime("%Y%m%d_%H%M%S") + "_mcp-configs")
            if not self.dry:
                os.makedirs(self.dir, exist_ok=True)
        return self.dir

    def save(self, path):
        """cp the original (by its real path) into the trash folder; a note says where it came from."""
        real = os.path.realpath(path)
        name = real.strip("/").replace("/", "__")
        dest = os.path.join(self.folder(), name)
        if not self.dry:
            shutil.copy2(real, dest)
            with open(os.path.join(self.dir, "MOVED.txt"), "a") as f:
                f.write("%s -> %s (copy of the original, before mcp-register edited it)\n" % (real, name))
        return dest

    def save_text(self, label, text):
        dest = os.path.join(self.folder(), label)
        if not self.dry:
            with open(dest, "w") as f:
                f.write(text)
            with open(os.path.join(self.dir, "MOVED.txt"), "a") as f:
                f.write("%s -> %s (copy of the original, before mcp-register edited it)\n" % (label.replace("__", "/"), label))
        return dest


def write_text(path, text, dry):
    """Write in place through the real path (a symlink stays a symlink), keeping the mode."""
    if dry:
        return
    real = os.path.realpath(path)
    os.makedirs(os.path.dirname(real), exist_ok=True)
    mode = os.stat(real).st_mode & 0o777 if os.path.exists(real) else 0o600
    tmp = real + ".mcp-register.tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.chmod(tmp, mode)
    os.replace(tmp, real)


def read_text(path):
    try:
        with open(path) as f:
            return f.read()
    except FileNotFoundError:
        return None


# ---------------------------------------------------------------- JSON files

def json_indent(text):
    m = re.search(r"\n([ \t]+)\S", text or "")
    return m.group(1) if m else "  "


def mentions(entry, script):
    return script in json.dumps(entry)


class JsonTarget:
    """A JSON file with a map of servers under `key`."""

    def __init__(self, path, key, make):
        self.path = os.path.expanduser(path)
        self.key = key
        self.make = make  # (script, env) -> entry

    def parse(self, text):
        if text is None or not text.strip():
            return {}
        return json.loads(text)

    def dump(self, data, original):
        indent = json_indent(original)
        out = json.dumps(data, indent=indent, ensure_ascii=False)
        return out + ("\n" if (original or "\n").endswith("\n") else "")

    @staticmethod
    def entry(state, label):
        """What register recorded for `label`: the names it added, whether
        it created the servers key, and whether the file was empty."""
        got = state.get(label)
        if isinstance(got, list):  # older state files
            return {"names": got, "created_key": False, "was_empty": False}
        return got or {"names": [], "created_key": False, "was_empty": False}

    def record(self, state, label, text, data_before_key, added):
        prev = self.entry(state, label)
        state[label] = {
            "names": sorted(set(prev["names"]) | set(added)),
            "created_key": prev["created_key"] or not data_before_key,
            "was_empty": prev["was_empty"] or (text is not None and not text.strip()),
        }

    def restored(self, data, rec, text):
        """The file's text once our names are gone: the servers key goes if
        register made it and it is now empty, an empty file stays empty."""
        if rec["created_key"] and not data.get(self.key):
            data.pop(self.key, None)
        if rec["was_empty"] and not data:
            return ""
        return self.dump(data, text)

    def register(self, state, backup, dry, report):
        text = read_text(self.path)
        data = self.parse(text)
        had_key = self.key in data
        table = data.setdefault(self.key, {})
        added = []
        for name, script, env in servers():
            have = [n for n, e in table.items() if mentions(e, script)]
            if have:
                report.append("%s: %s already registered as %s" % (self.path, name, ", ".join(have)))
                continue
            if name in table:
                report.append("%s: an unrelated %r entry exists, left alone (not added)" % (self.path, name))
                continue
            table[name] = self.make(script, env)
            added.append(name)
        if not added:
            return
        if text is not None:
            report.append("%s: backed up to %s" % (self.path, backup.save(self.path)))
        write_text(self.path, self.dump(data, text), dry)
        self.record(state, self.path, text, had_key, added)
        report.append("%s: added %s" % (self.path, ", ".join(added)))

    def unregister(self, state, backup, dry, report):
        rec = self.entry(state, self.path)
        names = rec["names"]
        text = read_text(self.path)
        if not names or text is None:
            return
        data = self.parse(text)
        table = data.get(self.key, {})
        removed = [n for n in names if n in table and any(mentions(table[n], s) for _, s, _ in servers() + [("", BRIDGE, {}), ("", VAULT, {})])]
        if removed:
            report.append("%s: backed up to %s" % (self.path, backup.save(self.path)))
            for n in removed:
                del table[n]
            write_text(self.path, self.restored(data, rec, text), dry)
            report.append("%s: removed %s" % (self.path, ", ".join(removed)))
        state.pop(self.path, None)

    def verify(self):
        text = read_text(self.path)
        if text is None:
            return "missing"
        if not text.strip():
            return "empty"
        data = json.loads(text)
        return "ok (%s: %s)" % (self.key, ", ".join(sorted(data.get(self.key, {}))) or "none")


# ---------------------------------------------------------------- TOML files

def toml_str(s):
    return json.dumps(s)


def toml_inline(env):
    return "{ " + ", ".join("%s = %s" % (k, toml_str(v)) for k, v in env.items()) + " }"


def toml_blocks(text):
    """[(table name, block text)] for each [mcp_servers.<name>] table."""
    out = []
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        m = re.match(r'^\s*\[mcp_servers\.("?)([^"\]]+)\1\]\s*$', lines[i])
        if m:
            j = i + 1
            while j < len(lines) and not re.match(r"^\s*\[", lines[j]):
                j += 1
            out.append((m.group(2), "\n".join(lines[i:j])))
            i = j
        else:
            i += 1
    return out


def toml_parse(text):
    try:
        import tomllib as toml  # Python 3.11+
    except ImportError:
        try:
            import tomli as toml
        except ImportError:
            return None
    return toml.loads(text)


ENV_VARS_RE = re.compile(r"^env_vars\s*=\s*(\[.*\])\s*$")


def env_vars_of(lines):
    """The names in an `env_vars = [...]` line among `lines`, or None."""
    for line in lines:
        m = ENV_VARS_RE.match(line.strip())
        if m:
            return json.loads(m.group(1))
    return None


class TomlTarget:
    def __init__(self, path, node, extra):
        self.path = os.path.expanduser(path)
        self.node = node
        self.extra = extra  # (name, env) -> list of extra lines

    def block(self, name, script, env):
        lines = [MARK_BEGIN.format(name=name), "[mcp_servers.%s]" % name,
                 "command = %s" % toml_str(self.node), "args = [%s]" % toml_str(script)]
        if env:
            lines.append("env = %s" % toml_inline(env))
        lines += self.extra(name, env)
        lines.append(MARK_END.format(name=name))
        return "\n".join(lines) + "\n"

    def own_block_re(self, name):
        return re.compile("^" + re.escape(MARK_BEGIN.format(name=name)) + r"\n.*?^" + re.escape(MARK_END.format(name=name)) + "$", re.S | re.M)

    def update_env_vars(self, text, names, report):
        """Adds the env_vars names this script now wants to the blocks it wrote
        itself (between its markers, for names in its state file). Every other
        line, and every entry it did not write, is left as it is."""
        for name, script, env in servers():
            want = env_vars_of(self.extra(name, env))
            if not want or name not in names:
                continue
            m = self.own_block_re(name).search(text)
            if not m:
                continue
            lines = m.group(0).split("\n")
            have = env_vars_of(lines)
            missing = [v for v in want if v not in (have or [])]
            if not missing:
                continue
            line = "env_vars = [%s]" % ", ".join(toml_str(v) for v in (have or []) + missing)
            if have is None:
                lines.insert(len(lines) - 1, line)
            else:
                lines = [line if ENV_VARS_RE.match(x.strip()) else x for x in lines]
            text = text[:m.start()] + "\n".join(lines) + text[m.end():]
            report.append("%s: %s env_vars added %s" % (self.path, name, ", ".join(missing)))
        return text

    def register(self, state, backup, dry, report):
        existed = os.path.exists(self.path)
        text = read_text(self.path)
        if text is None:
            text = ""
        updated = self.update_env_vars(text, JsonTarget.entry(state, self.path)["names"], report)
        blocks = toml_blocks(text)
        add = []
        for name, script, env in servers():
            have = [n for n, b in blocks if script in b]
            if have:
                report.append("%s: %s already registered as %s" % (self.path, name, ", ".join(have)))
                continue
            if any(n == name for n, _ in blocks):
                report.append("%s: an unrelated [mcp_servers.%s] exists, left alone (not added)" % (self.path, name))
                continue
            add.append((name, self.block(name, script, env)))
        if not add and updated == text:
            return
        new = updated
        if add:
            if new and not new.endswith("\n"):
                new += "\n"
            new += "\n" + "\n".join(b for _, b in add)
        if toml_parse("") is None:
            report.append("%s: no TOML parser here (tomllib/tomli); written unchecked" % self.path)
        else:
            toml_parse(new)  # raises before anything is written if the result would not parse
        if existed:
            report.append("%s: backed up to %s" % (self.path, backup.save(self.path)))
        write_text(self.path, new, dry)
        if add:
            prev = JsonTarget.entry(state, self.path)["names"]
            state[self.path] = {"names": sorted(set(prev) | {n for n, _ in add}), "created_key": False, "was_empty": False}
            report.append("%s: added %s" % (self.path, ", ".join(n for n, _ in add)))

    def unregister(self, state, backup, dry, report):
        text = read_text(self.path)
        names = JsonTarget.entry(state, self.path)["names"]
        if text is None or not names:
            return
        new = text
        removed = []
        for name in names:
            # register wrote "\n" + block (ending in "\n") per server
            pat = re.compile(r"\n?" + re.escape(MARK_BEGIN.format(name=name)) + r"\n.*?" + re.escape(MARK_END.format(name=name)) + r"\n", re.S)
            new2 = pat.sub("", new, count=1)
            if new2 != new:
                removed.append(name)
                new = new2
        if removed:
            report.append("%s: backed up to %s" % (self.path, backup.save(self.path)))
            write_text(self.path, new, dry)
            report.append("%s: removed %s" % (self.path, ", ".join(removed)))
        state.pop(self.path, None)

    def verify(self):
        text = read_text(self.path)
        if text is None:
            return "missing"
        data = toml_parse(text)
        if data is None:
            return "unchecked (no TOML parser)"
        return "ok (mcp_servers: %s)" % (", ".join(sorted(data.get("mcp_servers", {}))) or "none")


# ---------------------------------------------------------------- prep-pro Antigravity over ssh

SSH = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]


def remote_ok(report):
    probe = SSH + [REMOTE_HOST, "ssh -o BatchMode=yes -o ConnectTimeout=10 %s true" % REMOTE_HOP]
    try:
        r = subprocess.run(probe, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=40)
    except (OSError, subprocess.TimeoutExpired):
        report.append("%s: ssh check failed to run; Antigravity there left alone" % REMOTE_HOST)
        return False
    if r.returncode != 0:
        report.append("%s: `ssh %s true` does not work without a password (exit %d); Antigravity there left alone"
                      % (REMOTE_HOST, REMOTE_HOP, r.returncode))
        return False
    report.append("%s: `ssh -o BatchMode=yes %s true` works" % (REMOTE_HOST, REMOTE_HOP))
    return True


def remote_read():
    r = subprocess.run(SSH + [REMOTE_HOST, "f=%s; test -e \"$f\" && cat \"$f\" || printf '__MISSING__'" % REMOTE_FILE],
                       capture_output=True, text=True, timeout=40)
    if r.returncode != 0:
        raise RuntimeError("could not read %s:%s" % (REMOTE_HOST, REMOTE_FILE))
    return None if r.stdout == "__MISSING__" else r.stdout


def remote_write(text):
    # Through the real path, so a symlinked config stays a symlink.
    cmd = ("f=%s; r=$(python3 -c 'import os,sys;print(os.path.realpath(os.path.expanduser(sys.argv[1])))' \"$f\"); "
           "mkdir -p \"$(dirname \"$r\")\" && cat > \"$r.mcp-register.tmp\" && mv \"$r.mcp-register.tmp\" \"$r\"") % REMOTE_FILE
    subprocess.run(SSH + [REMOTE_HOST, cmd], input=text, text=True, check=True, timeout=40)


def remote_entry(script, env):
    return {"command": "ssh", "args": ["-o", "BatchMode=yes", REMOTE_HOP, HOST_NODE, script], "env": {}}


class RemoteTarget(JsonTarget):
    label = "%s:%s" % (REMOTE_HOST, REMOTE_FILE)

    def __init__(self):
        super().__init__(REMOTE_FILE, "mcpServers", remote_entry)
        self.path = self.label

    def register(self, state, backup, dry, report):
        if not remote_ok(report):
            return
        text = remote_read()
        data = self.parse(text)
        had_key = self.key in data
        table = data.setdefault(self.key, {})
        added = []
        for name, script, env in servers():
            have = [n for n, e in table.items() if mentions(e, script)]
            if have:
                report.append("%s: %s already registered as %s" % (self.label, name, ", ".join(have)))
                continue
            if name in table:
                report.append("%s: an unrelated %r entry exists, left alone (not added)" % (self.label, name))
                continue
            table[name] = remote_entry(script, env)
            added.append(name)
        if not added:
            return
        if text is not None:
            report.append("%s: backed up to %s" % (self.label, backup.save_text("prep-pro__.gemini__antigravity__mcp_config.json", text)))
        if not dry:
            remote_write(self.dump(data, text))
        self.record(state, self.label, text, had_key, added)
        report.append("%s: added %s" % (self.label, ", ".join(added)))

    def unregister(self, state, backup, dry, report):
        rec = self.entry(state, self.label)
        names = rec["names"]
        if not names:
            return
        text = remote_read()
        if text is None:
            state.pop(self.label, None)
            return
        data = self.parse(text)
        table = data.get(self.key, {})
        removed = [n for n in names if n in table and (mentions(table[n], BRIDGE) or mentions(table[n], VAULT))]
        if removed:
            report.append("%s: backed up to %s" % (self.label, backup.save_text("prep-pro__.gemini__antigravity__mcp_config.json", text)))
            for n in removed:
                del table[n]
            if not dry:
                remote_write(self.restored(data, rec, text))
            report.append("%s: removed %s" % (self.label, ", ".join(removed)))
        state.pop(self.label, None)

    def verify(self):
        try:
            text = remote_read()
        except Exception as e:  # noqa: BLE001
            return "unreachable (%s)" % e
        if text is None:
            return "missing"
        if not text.strip():
            return "empty"
        return "ok (mcpServers: %s)" % (", ".join(sorted(json.loads(text).get("mcpServers", {}))) or "none")


# ---------------------------------------------------------------- targets

def codex_extra(name, env):
    # Codex hands MCP servers only a short list of variables; forward the Happy
    # session so the bridge (and the vault) know which chat they serve, and the
    # parent session of a fork or side chat so its browser starts with the
    # parent's login.
    return ['env_vars = ["HAPPY_SESSION_ID", "HAPPY_FORKED_FROM_SESSION_ID"]', "startup_timeout_sec = 20", "tool_timeout_sec = 600"]


def agent_extra(name, env):
    # Happy Agent caps tool_timeout_sec at 600.
    return ["enabled = true", "startup_timeout_sec = 20", "tool_timeout_sec = 600"]


def targets(remote=True):
    out = [
        TomlTarget("~/.codex/config.toml", HOST_NODE, codex_extra),
        JsonTarget("~/.config/opencode/opencode.json", "mcp", lambda s, env: {
            "type": "local", "command": [HOST_NODE, s], "enabled": True, **({"environment": dict(env)} if env else {})}),
        JsonTarget("~/.gemini/settings.json", "mcpServers", lambda s, env: {
            "command": HOST_NODE, "args": [s], "env": dict(env), "timeout": 600000}),
        JsonTarget("~/.gemini/config/mcp_config.json", "mcpServers", lambda s, env: {
            "command": HOST_NODE, "args": [s], "env": dict(env)}),
        JsonTarget("~/.claude.json", "mcpServers", lambda s, env: {
            "type": "stdio", "command": "node", "args": [s], "env": {}}),
        TomlTarget("~/.local/share/happy-agent/happy/config/mcp.toml", AGENT_NODE, agent_extra),
    ]
    if remote:
        out.append(RemoteTarget())
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("action", choices=["register", "unregister", "check"])
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--no-remote", action="store_true", help="leave prep-pro alone")
    a = ap.parse_args()

    if not os.path.isfile(BRIDGE):
        sys.exit("no bridge at %s" % BRIDGE)
    state = load_state()
    backup = Backup(a.dry_run)
    report = []
    failed = False
    for t in targets(remote=not a.no_remote):
        try:
            if a.action == "register":
                t.register(state, backup, a.dry_run, report)
            elif a.action == "unregister":
                t.unregister(state, backup, a.dry_run, report)
        except Exception as e:  # noqa: BLE001
            failed = True
            report.append("%s: FAILED: %s" % (t.path, e))
    save_state(state, a.dry_run)
    if a.dry_run:
        report.insert(0, "dry run: nothing written")
    print("\n".join(report))
    print("\nparse check:")
    for t in targets(remote=not a.no_remote):
        try:
            print("  %-60s %s" % (t.path, t.verify()))
        except Exception as e:  # noqa: BLE001
            failed = True
            print("  %-60s DOES NOT PARSE: %s" % (t.path, e))
    if a.action != "check":
        print("\nRestart to pick these up: new Codex, Gemini, opencode, agy and Claude sessions read them at start;"
              "\nHappy Agent reloads mcp.toml without a daemon restart (or restart happy-agent); Antigravity on prep-pro: reload its MCP servers.")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
