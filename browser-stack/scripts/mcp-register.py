#!/usr/bin/env python3
"""Register the live browser bridge and the vault MCP server with every harness.

Use through make (browser-stack/Makefile, or selfhost/Makefile, which includes it):
  make mcp-register          add the servers where they are missing
  make mcp-unregister        remove what mcp-register added (and only that)
  make mcp-register DRY=1    say what would change, write nothing
  make mcp-register NO_REMOTE=1   leave the Macs alone

Servers:
  happy-browser-bridge  node selfhost/browser/bridge/mcp.mjs (reads its tokens
                        from their own files; no token is written anywhere)
  vault                 node selfhost/vault-mcp/mcp.mjs, only if that file exists

Files here (each one that exists, or that its harness reads, is edited in place):
  ~/.codex/config.toml                              [mcp_servers.<name>], env_vars forwards HAPPY_SESSION_ID
                                                    and HAPPY_FORKED_FROM_SESSION_ID
  ~/.gemini/settings.json                           "mcpServers" (Gemini CLI)
  ~/.gemini/config/mcp_config.json                  "mcpServers" (Antigravity / agy)
  ~/.claude.json                                    top-level "mcpServers", stdio
  ~/.local/share/happy-agent/happy/config/mcp.toml  [mcp_servers.<name>] (container paths)
  ~/.claude/skills/agent-vault/SKILL.md             a copy of .agents/skills/agent-vault/SKILL.md
                                                    (here and on each Mac)

Not here: ~/.config/opencode/opencode.json(c) on prep-ml is never read or written
(register, unregister and check all skip it); only the Macs' opencode is registered.

Files on the Macs (REMOTES below), over ssh, for the harnesses installed there.
Each Mac is used only if `ssh <mac> 'ssh -o BatchMode=yes prep-ml true'` works.
A missing file is created only when its folder exists (for Gemini CLI, also when
the gemini binary is installed: its ~/.gemini is made on first run). Their entries run the
servers on prep-ml through a `/bin/sh -c` wrapper (remote_wrapper): ssh forwards
no environment, so the wrapper puts HAPPY_SESSION_ID, CLAUDE_CODE_SESSION_ID and
HAPPY_FORKED_FROM_SESSION_ID on the remote command line, each one blanked
unless it matches ^[A-Za-z0-9_-]{1,128}$ (prep-ml's shell parses it again).

Before a file is changed its original is copied to
/home/prep/happy/trash/<ts>_mcp-configs/ (a Mac's to ~/happy-trash/<ts>_mcp-configs/
on that Mac). Everything else in each file is kept. An entry already pointing at
the same server script, under any name, is left alone, except that on the Macs
an entry recorded as ours is brought up to date (the older plain `ssh prep-ml
node ...` ones). What was added is recorded in
~/.local/share/happy-mcp-register/state.json so that unregister removes only
that (and moves a file it created on a Mac to that Mac's trash). In an entry
recorded there (and only there), names missing from its env_vars list are added
on the next register.
"""

import argparse
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
REPO = "/home/prep/happy"
TRASH = os.environ.get("HAPPY_MCP_REGISTER_TRASH") or os.path.join(REPO, "trash")
# The servers live in browser-stack/; every harness config (here and on the Macs) names them by
# these paths, which are symlinks into browser-stack/ so those configs keep working unchanged.
# Changing them would rewrite every config, the Macs' included.
BRIDGE = os.path.join(REPO, "selfhost/browser/bridge/mcp.mjs")
VAULT = os.path.join(REPO, "selfhost/vault-mcp/mcp.mjs")
STATE = os.path.join(HOME, ".local/share/happy-mcp-register/state.json")
HOST_NODE = shutil.which("node") or "/usr/bin/node"
# The happy-agent container mounts the host's node here (browser-stack/browser/README.md).
AGENT_NODE = "/usr/local/bin/node"
# Harnesses with a tool time limit: browser_wait_for_human returns inside it.
WAIT = {"BRIDGE_WAIT_MAX_S": "570"}
# Happy Agent serves all its chats from one bridge process; the bridge finds each call's chat in
# the daemon's own database (browser-stack/browser/README.md, "Happy Agent"). Here the container sees
# the host's path; a Mac's daemon is read over ssh from prep-ml (BRIDGE_AGENT_SSH).
LOCAL_AGENT_DB = os.path.join(HOME, ".local/share/happy-agent/.happy/agent/agent.sqlite")
REMOTE_AGENT_DB = "/Users/cprepos/.local/share/happy-agent/.happy/agent/agent.sqlite"  # on the Mac
REMOTE_PYTHON = "/usr/bin/python3"  # on the Mac


def agent_env(script, env, host=None):
    """The bridge's env in a Happy Agent config: where that daemon's database is."""
    if script != BRIDGE:
        return dict(env)
    if host is None:
        return dict(env, BRIDGE_AGENT_DB=LOCAL_AGENT_DB)
    return dict(env, BRIDGE_AGENT_DB=REMOTE_AGENT_DB, BRIDGE_AGENT_SSH=host, BRIDGE_AGENT_PYTHON=REMOTE_PYTHON)
RUN_TS = time.strftime("%Y%m%d_%H%M%S")

# The Macs: which harness configs to edit on each (the ones installed there).
REMOTE_HOP = "prep-ml"
REMOTE_NODE = "/usr/bin/node"   # on prep-ml
WRAP_SSH = "/usr/bin/ssh"       # on the Mac
REMOTE_TRASH = "~/happy-trash"  # on the Mac
# How a Mac reaches the bridge: its LAN listener (BRIDGE_LAN_BIND), not prep-ml's localhost.
# The bridge's MCP server on prep-ml writes the links a Mac chat gets with this base.
REMOTE_LINK_BASE = "http://192.168.2.72:6090"
# Where a harness binary may be on a Mac (for creating a config folder it lacks).
REMOTE_BIN_DIRS = ["/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin", "~/.npm-global/bin", "~/.bun/bin", "~/.opencode/bin"]
# The agent-vault skill, installed for Claude on this machine and on each Mac.
SKILL_SRC = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                                          ".agents", "skills", "agent-vault", "SKILL.md"))
SKILL_DEST = "~/.claude/skills/agent-vault/SKILL.md"
REMOTES = [
    ("prep-air", ["claude", "opencode", "gemini", "happy-agent"]),
    ("prep-pro", ["claude", "codex", "opencode", "gemini", "antigravity", "happy-agent"]),
]
# The chat ids a Mac harness hands its MCP servers, passed on to prep-ml.
SESSION_VARS = ["HAPPY_SESSION_ID", "CLAUDE_CODE_SESSION_ID", "HAPPY_FORKED_FROM_SESSION_ID"]
ID_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"

MARK_BEGIN = "# >>> happy mcp-register: {name}"
MARK_END = "# <<< happy mcp-register: {name}"


def servers():
    """(name, script, extra env for harnesses with a tool time limit)."""
    out = [("happy-browser-bridge", BRIDGE, WAIT)]
    if os.path.isfile(VAULT):
        out.append(("vault", VAULT, {}))
    return out


# ---------------------------------------------------------------- the Mac wrapper

SAFE_WORD = re.compile(r"^[A-Za-z0-9_./:-]+$")
SAFE_KEY = re.compile(r"^[A-Z_][A-Z0-9_]*$")


def remote_wrapper(script, env, ssh=WRAP_SSH, hop=REMOTE_HOP, node=REMOTE_NODE):
    """The `/bin/sh -c` text that runs `script` on prep-ml over ssh with the chat's ids.

    Each id is checked against ^[A-Za-z0-9_-]{1,128}$ and blanked if it fails: the
    remote command is a string that prep-ml's shell parses again. The character
    list is spelled out (no ranges), so the check does not depend on the locale.
    Everything else in it is fixed here and checked to need no quoting.
    """
    for w in (ssh, hop, node, script):
        if not SAFE_WORD.match(w):
            raise ValueError("unsafe word for the remote command: %r" % w)
    for k, v in env.items():
        if not SAFE_KEY.match(k) or not SAFE_WORD.match(v):
            raise ValueError("unsafe env for the remote command: %r" % k)
    parts = ['ok() { case "$1" in ""|*[!%s]*) return 1;; esac; [ ${#1} -le 128 ]; }' % ID_CHARS]
    for i, var in enumerate(SESSION_VARS):
        parts.append('v%d=; ok "${%s-}" && v%d="$%s"' % (i, var, i, var))
    remote = ['%s="$v%d"' % (var, i) for i, var in enumerate(SESSION_VARS)]
    remote += ["%s=%s" % (k, v) for k, v in sorted(env.items())]
    remote += [node, script]
    parts.append("exec %s -o BatchMode=yes -o LogLevel=ERROR %s %s" % (ssh, hop, " ".join(remote)))
    return "; ".join(parts)


def remote_argv(script, env):
    if script == BRIDGE:
        env = dict(env, BRIDGE_PUBLIC_BASE=REMOTE_LINK_BASE)
    return ["-c", remote_wrapper(script, env)]


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
            self.dir = os.path.join(TRASH, RUN_TS + "_mcp-configs")
            if not self.dry:
                os.makedirs(self.dir, exist_ok=True)
        return self.dir

    def free(self, name):
        """A name in the trash folder no earlier copy uses (a same-second run shares the folder)."""
        dest, i = os.path.join(self.folder(), name), 1
        while os.path.lexists(dest):
            dest, i = os.path.join(self.folder(), "%s.%d" % (name, i)), i + 1
        return dest

    def save(self, path):
        """cp the original (by its real path) into the trash folder; a note says where it came from."""
        real = os.path.realpath(path)
        dest = self.free(real.strip("/").replace("/", "__"))
        name = os.path.basename(dest)
        if not self.dry:
            shutil.copy2(real, dest)
            with open(os.path.join(self.dir, "MOVED.txt"), "a") as f:
                f.write("%s -> %s (copy of the original, before mcp-register edited it)\n" % (real, name))
        return dest

    def move(self, path):
        """mv a file register created (by its real path) into the trash folder."""
        real = os.path.realpath(path)
        dest = self.free(real.strip("/").replace("/", "__"))
        name = os.path.basename(dest)
        if not self.dry:
            shutil.move(real, dest)
            with open(os.path.join(self.dir, "MOVED.txt"), "a") as f:
                f.write("%s -> %s (created by mcp-register, moved here by mcp-unregister)\n" % (real, name))
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


class LocalIO:
    """Files on this machine."""
    remote = False

    def label(self, path):
        return os.path.expanduser(path)

    def available(self, report):
        return True

    def read(self, path):
        return read_text(os.path.expanduser(path))

    def may_create(self, path):
        return True

    def parent_exists(self, path):
        return os.path.isdir(os.path.dirname(os.path.realpath(os.path.expanduser(path))))

    def write(self, path, text, dry):
        write_text(os.path.expanduser(path), text, dry)

    def backup(self, path, backup, dry):
        return backup.save(os.path.expanduser(path))

    def trash(self, path, dry):
        raise RuntimeError("local files are never moved out")


LOCAL = LocalIO()

SSH = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "LogLevel=ERROR"]

# Runs on the Mac with its own python3. Paths go through realpath, so a symlinked
# config stays a symlink. Prints JSON for read, the destination for backup/trash.
REMOTE_HELPER = r'''
import json, os, shutil, sys
op, p = sys.argv[1], os.path.expanduser(sys.argv[2])
r = os.path.realpath(p)
if op == "read":
    out = {"exists": os.path.exists(r), "parent": os.path.isdir(os.path.dirname(r))}
    if out["exists"]:
        with open(r) as f:
            out["text"] = f.read()
    sys.stdout.write(json.dumps(out))
elif op == "write":
    data = sys.stdin.read()
    if not os.path.isdir(os.path.dirname(r)):
        os.makedirs(os.path.dirname(r))
    mode = os.stat(r).st_mode & 0o777 if os.path.exists(r) else 0o600
    tmp = r + ".mcp-register.tmp"
    with open(tmp, "w") as f:
        f.write(data)
    os.chmod(tmp, mode)
    os.replace(tmp, r)
elif op in ("backup", "trash"):
    d = os.path.expanduser(sys.argv[3])
    os.makedirs(d, exist_ok=True)
    name = base = r.strip("/").replace("/", "__")
    i = 1
    while os.path.lexists(os.path.join(d, name)):
        name, i = "%s.%d" % (base, i), i + 1
    dest = os.path.join(d, name)
    if op == "backup":
        shutil.copy2(r, dest)
        why = "copy of the original, before mcp-register edited it"
    else:
        shutil.move(r, dest)
        why = "created by mcp-register, moved here by mcp-unregister"
    with open(os.path.join(d, "MOVED.txt"), "a") as f:
        f.write("%s -> %s (%s)\n" % (r, name, why))
    sys.stdout.write(dest)
elif op == "which":
    dirs = sys.argv[3:]
    sys.stdout.write(json.dumps(any(os.access(os.path.join(os.path.expanduser(d), sys.argv[2]), os.X_OK) for d in dirs)))
elif op == "trashdir":
    d = os.path.expanduser(sys.argv[3])
    if os.path.isdir(r) and not os.listdir(r):
        os.makedirs(d, exist_ok=True)
        name = r.strip("/").replace("/", "__")
        shutil.move(r, os.path.join(d, name))
        with open(os.path.join(d, "MOVED.txt"), "a") as f:
            f.write("%s -> %s (empty folder created by mcp-register, moved here by mcp-unregister)\n" % (r, name))
        sys.stdout.write(os.path.join(d, name))
elif op == "restore":
    src, d = sys.argv[3], os.path.expanduser(sys.argv[4])
    if not os.path.isfile(src):
        sys.exit("no backup at " + src)
    os.makedirs(d, exist_ok=True)
    name = r.strip("/").replace("/", "__") + ".before-unregister"
    shutil.copy2(r, os.path.join(d, name))
    with open(os.path.join(d, "MOVED.txt"), "a") as f:
        f.write("%s -> %s (copy before mcp-unregister put back %s)\n" % (r, name, src))
    mode = os.stat(r).st_mode & 0o777
    tmp = r + ".mcp-register.tmp"
    shutil.copyfile(src, tmp)
    os.chmod(tmp, mode)
    os.replace(tmp, r)
    sys.stdout.write(os.path.join(d, name))
else:
    sys.exit("unknown op " + op)
'''

PROBED = {}


class RemoteIO:
    """Files on a Mac, read and written over ssh by REMOTE_HELPER."""
    remote = True

    def __init__(self, host):
        self.host = host
        self.parents = {}

    def label(self, path):
        return "%s:%s" % (self.host, path)

    def trash_dir(self):
        return "%s/%s_mcp-configs" % (REMOTE_TRASH, RUN_TS)

    def available(self, report):
        """`ssh <mac> 'ssh -o BatchMode=yes prep-ml true'`, once per Mac per run."""
        if self.host not in PROBED:
            probe = SSH + [self.host, "ssh -o BatchMode=yes -o ConnectTimeout=10 %s true" % REMOTE_HOP]
            try:
                r = subprocess.run(probe, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=40)
                ok, why = r.returncode == 0, "exit %d" % r.returncode
            except (OSError, subprocess.TimeoutExpired) as e:
                ok, why = False, type(e).__name__
            PROBED[self.host] = ok
            if ok:
                report.append("%s: `ssh -o BatchMode=yes %s true` works" % (self.host, REMOTE_HOP))
            else:
                report.append("%s: `ssh %s true` does not work without a password (%s); its configs left alone"
                              % (self.host, REMOTE_HOP, why))
        return PROBED[self.host]

    def run(self, args, stdin=None):
        cmd = " ".join(shlex.quote(a) for a in ["/usr/bin/python3", "-c", REMOTE_HELPER] + args)
        r = subprocess.run(SSH + [self.host, cmd], input=stdin, capture_output=True, text=True, timeout=60)
        if r.returncode != 0:
            raise RuntimeError("%s: %s %s failed (exit %d): %s"
                               % (self.host, args[0], args[1], r.returncode, r.stderr.strip()[-300:]))
        return r.stdout

    def read(self, path):
        got = json.loads(self.run(["read", path]))
        self.parents[path] = got["parent"]
        return got.get("text") if got["exists"] else None

    def may_create(self, path):
        return self.parents.get(path, False)

    def parent_exists(self, path):
        if path not in self.parents:
            self.read(path)
        return self.parents[path]

    def has_binary(self, name):
        return json.loads(self.run(["which", name] + REMOTE_BIN_DIRS))

    def trash_dir_if_empty(self, folder, dry):
        """Move `folder` to the trash if it is empty; its destination, or None."""
        if dry:
            return None
        out = self.run(["trashdir", folder, self.trash_dir()])
        return "%s:%s" % (self.host, out) if out else None

    def write(self, path, text, dry):
        if not dry:
            self.run(["write", path], stdin=text)

    def backup(self, path, backup, dry):
        if dry:
            return "%s:%s/" % (self.host, self.trash_dir())
        return "%s:%s" % (self.host, self.run(["backup", path, self.trash_dir()]))

    def trash(self, path, dry):
        if dry:
            return "%s:%s/" % (self.host, self.trash_dir())
        return "%s:%s" % (self.host, self.run(["trash", path, self.trash_dir()]))

    def restore(self, path, saved, dry):
        """Put the copy `saved` ("<host>:<path>", from backup) back over `path`;
        the current file is copied to the trash first."""
        src = saved.split(":", 1)[1]
        if dry:
            return "%s:%s/" % (self.host, self.trash_dir())
        return "%s:%s" % (self.host, self.run(["restore", path, src, self.trash_dir()]))


def sha(text):
    return hashlib.sha256(text.encode()).hexdigest()


def mac_record(io, prev, rec, text, saved, written):
    """The extra a Mac file's state record carries: whether register created the
    file, every backup it took, the backup of the original (taken when register
    first added to it) and a hash of what it last wrote. unregister puts the
    original back when the file still is what register wrote."""
    if not io.remote:
        return rec
    if prev["created_file"] or text is None:
        rec["created_file"] = True
    backups = prev["backups"] + ([saved] if saved else [])
    if backups:
        rec["backups"] = backups
    original = prev.get("original_backup") or (saved if not prev["names"] else None)
    if original:
        rec["original_backup"] = original
    if written is not None:
        rec["written_sha"] = sha(written)
    return rec


def restore_original(target, rec, text, dry, report):
    """On a Mac: when the file is exactly what register last wrote, put back the
    original it backed up. False (and nothing done) otherwise."""
    if not (target.io.remote and rec.get("original_backup") and rec.get("written_sha") == sha(text)):
        return False
    try:
        moved = target.io.restore(target.file, rec["original_backup"], dry)
    except RuntimeError as e:
        report.append("%s: could not put the original back (%s); removing the entries instead" % (target.path, e))
        return False
    report.append("%s: unchanged since register; put back the original %s (the current file copied to %s)"
                  % (target.path, rec["original_backup"], moved))
    return True


# ---------------------------------------------------------------- JSON files

def json_indent(text):
    m = re.search(r"\n([ \t]+)\S", text or "")
    return m.group(1) if m else "  "


def strip_jsonc(text):
    """JSON with comments (opencode.jsonc) as plain JSON text: // and /* */
    comments and trailing commas go, strings are kept as they are. Returns
    (json text, whether it had comments)."""
    out, i, n, had = [], 0, len(text), False
    while i < n:
        c = text[i]
        if c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            out.append(text[i:j + 1])
            i = j + 1
        elif text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
            had = True
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            if j < 0:
                raise ValueError("unterminated /* comment")
            out.append(" ")
            i = j + 2
            had = True
        else:
            out.append(c)
            i += 1
    plain = "".join(out)
    # Trailing commas: a comma (outside a string) followed only by space and } or ].
    res, i, n = [], 0, len(plain)
    while i < n:
        c = plain[i]
        if c == '"':
            j = i + 1
            while j < n and plain[j] != '"':
                j += 2 if plain[j] == "\\" else 1
            res.append(plain[i:j + 1])
            i = j + 1
            continue
        if c == ",":
            j = i + 1
            while j < n and plain[j] in " \t\r\n":
                j += 1
            if j < n and plain[j] in "}]":
                i += 1
                continue
        res.append(c)
        i += 1
    return "".join(res), had


def mentions(entry, script):
    return script in json.dumps(entry)


def ours(entry):
    return mentions(entry, BRIDGE) or mentions(entry, VAULT)


def record_of(state, label):
    """What register recorded for `label`: the names it added, whether it
    created the servers key, whether the file was empty, whether it created
    the file (Macs only) and where the original was backed up."""
    got = state.get(label)
    if isinstance(got, list):  # older state files
        got = {"names": got}
    rec = {"names": [], "created_key": False, "was_empty": False, "created_file": False, "backups": []}
    rec.update(got or {})
    return rec


class JsonTarget:
    """A JSON file with a map of servers under `key`."""

    def __init__(self, path, key, make, io=LOCAL, create_with=None):
        self.io = io
        self.file = path
        self.path = io.label(path)
        self.key = key
        self.make = make  # (script, env) -> entry
        # A harness binary: when it is installed on the Mac, a missing folder
        # for this file is created (Gemini CLI makes ~/.gemini only on first run).
        self.create_with = create_with

    def resolve(self, state, look=True):
        """Settle which file this target edits (see OpencodeTarget)."""

    def parse(self, text):
        if text is None or not text.strip():
            return {}
        if self.file.endswith(".jsonc"):
            return json.loads(strip_jsonc(text)[0])
        return json.loads(text)

    def comments_dropped(self, text):
        return bool(text) and self.file.endswith(".jsonc") and strip_jsonc(text)[1]

    def dump(self, data, original):
        indent = json_indent(original)
        out = json.dumps(data, indent=indent, ensure_ascii=False)
        return out + ("\n" if (original or "\n").endswith("\n") else "")

    entry = staticmethod(record_of)

    def record(self, state, label, text, data_before_key, added, saved=None, written=None):
        prev = record_of(state, label)
        state[label] = mac_record(self.io, prev, {
            "names": sorted(set(prev["names"]) | set(added)),
            "created_key": prev["created_key"] or not data_before_key,
            "was_empty": prev["was_empty"] or (text is not None and not text.strip()),
        }, text, saved, written)

    def restored(self, data, rec, text):
        """The file's text once our names are gone: the servers key goes if
        register made it and it is now empty, an empty file stays empty, and a
        file register created on a Mac goes (None)."""
        if rec["created_key"] and not data.get(self.key):
            data.pop(self.key, None)
        if rec["created_file"] and not data:
            return None
        if rec["was_empty"] and not data:
            return ""
        return self.dump(data, text)

    def register(self, state, backup, dry, report):
        if not self.io.available(report):
            return
        self.resolve(state)
        text = self.io.read(self.file)
        made_dir = None
        if text is None and not self.io.may_create(self.file):
            if not (self.create_with and self.io.has_binary(self.create_with)):
                report.append("%s: missing, and so is its folder; left alone" % self.path)
                return
            made_dir = os.path.dirname(self.file)
        data = self.parse(text)
        had_key = self.key in data
        table = data.setdefault(self.key, {})
        mine = record_of(state, self.path)["names"]
        added, upgraded = [], []
        for name, script, env in servers():
            want = self.make(script, env)
            have = [n for n, e in table.items() if mentions(e, script)]
            if have:
                # On a Mac, an entry recorded as ours is brought up to date.
                if self.io.remote and name in have and name in mine and table[name] != want:
                    table[name] = want
                    upgraded.append(name)
                    continue
                report.append("%s: %s already registered as %s" % (self.path, name, ", ".join(have)))
                continue
            if name in table:
                report.append("%s: an unrelated %r entry exists, left alone (not added)" % (self.path, name))
                continue
            table[name] = want
            added.append(name)
        if not added and not upgraded:
            return
        saved = None
        if text is not None:
            saved = self.io.backup(self.file, backup, dry)
            report.append("%s: backed up to %s" % (self.path, saved))
        if self.comments_dropped(text):
            report.append("%s: its comments are not kept (the original, with them, is in the backup)" % self.path)
        written = self.dump(data, text)
        self.io.write(self.file, written, dry)
        self.record(state, self.path, text, had_key, added, saved, written)
        if made_dir:
            state[self.path]["created_dir"] = made_dir
            report.append("%s: created %s (%s is installed there)" % (self.path, made_dir, self.create_with))
        if added:
            report.append("%s: added %s%s" % (self.path, ", ".join(added), " (new file)" if text is None else ""))
        if upgraded:
            report.append("%s: updated %s to the session-keyed wrapper" % (self.path, ", ".join(upgraded)))

    def unregister(self, state, backup, dry, report):
        self.resolve(state, look=False)
        rec = record_of(state, self.path)
        names = rec["names"]
        if not names or not self.io.available(report):
            return
        text = self.io.read(self.file)
        if text is None:
            state.pop(self.path, None)
            return
        if restore_original(self, rec, text, dry, report):
            state.pop(self.path, None)
            return
        data = self.parse(text)
        table = data.get(self.key, {})
        removed = [n for n in names if n in table and ours(table[n])]
        if removed:
            for n in removed:
                del table[n]
            out = self.restored(data, rec, text)
            if out is None:
                report.append("%s: removed %s; the file it created moved to %s"
                              % (self.path, ", ".join(removed), self.io.trash(self.file, dry)))
                if rec.get("created_dir"):
                    moved = self.io.trash_dir_if_empty(rec["created_dir"], dry)
                    if moved:
                        report.append("%s: the empty folder it created moved to %s" % (self.path, moved))
            else:
                report.append("%s: backed up to %s" % (self.path, self.io.backup(self.file, backup, dry)))
                self.io.write(self.file, out, dry)
                report.append("%s: removed %s" % (self.path, ", ".join(removed)))
        state.pop(self.path, None)

    def verify(self):
        if self.io.remote and not PROBED.get(self.io.host):
            return "skipped (no ssh)"
        text = self.io.read(self.file)
        if text is None:
            return "missing"
        if not text.strip():
            return "empty"
        data = self.parse(text)
        return "ok (%s: %s)" % (self.key, ", ".join(sorted(data.get(self.key, {}))) or "none")


class OpencodeTarget(JsonTarget):
    """opencode reads ~/.config/opencode/opencode.json or opencode.jsonc. The
    one recorded in the state file wins, then the one that exists, then .json."""

    NAMES = ["~/.config/opencode/opencode.json", "~/.config/opencode/opencode.jsonc"]

    def __init__(self, make, io=LOCAL):
        super().__init__(self.NAMES[0], "mcp", make, io)
        self.resolved = False

    def resolve(self, state, look=True):
        if self.resolved:
            return
        pick = next((p for p in self.NAMES if self.io.label(p) in state), None)
        if pick is None and not look:
            return  # unregister: nothing recorded for either name
        if pick is None:
            pick = next((p for p in self.NAMES if self.io.read(p) is not None), self.NAMES[0])
        self.file, self.path, self.resolved = pick, self.io.label(pick), True

    def verify(self):
        if not self.resolved and not (self.io.remote and not PROBED.get(self.io.host)):
            self.resolve(load_state())
        return super().verify()


# ---------------------------------------------------------------- the agent-vault skill

class SkillTarget:
    """The repo's agent-vault skill, copied to ~/.claude/skills/agent-vault/.

    An existing copy that differs is backed up (./trash locally, ~/happy-trash on
    a Mac) before it is replaced. unregister puts back the original copy it
    backed up first, or moves the file (and the empty folder) it created to the
    trash; a copy changed since register wrote it is left as it is."""

    def __init__(self, io=LOCAL, src=None, dest=SKILL_DEST):
        self.io = io
        self.src = src or SKILL_SRC
        self.file = dest
        self.path = io.label(dest)

    def source(self):
        return read_text(self.src)

    def register(self, state, backup, dry, report):
        want = self.source()
        if want is None:
            report.append("%s: no skill at %s; left alone" % (self.path, self.src))
            return
        if not self.io.available(report):
            return
        have = self.io.read(self.file)
        prev = state.get(self.path) or {}
        if have == want:
            report.append("%s: skill up to date" % self.path)
            return
        rec = dict(prev, skill=True)
        if have is None:
            if not prev:
                rec["created_file"] = True
                if not self.io.parent_exists(self.file):
                    rec["created_dir"] = os.path.dirname(self.file)
        else:
            saved = self.io.backup(self.file, backup, dry)
            report.append("%s: backed up to %s" % (self.path, saved))
            rec["backups"] = prev.get("backups", []) + [saved]
            if not prev:
                rec["original_backup"] = saved
        self.io.write(self.file, want, dry)
        rec["written_sha"] = sha(want)
        state[self.path] = rec
        report.append("%s: installed the agent-vault skill%s" % (self.path, " (new file)" if have is None else " (replaced)"))

    def unregister(self, state, backup, dry, report):
        rec = state.get(self.path)
        if not rec or not self.io.available(report):
            return
        have = self.io.read(self.file)
        if have is None:
            state.pop(self.path, None)
            return
        if rec.get("written_sha") != sha(have):
            report.append("%s: changed since register; left as it is" % self.path)
            state.pop(self.path, None)
            return
        if rec.get("original_backup"):
            if self.io.remote:
                moved = self.io.restore(self.file, rec["original_backup"], dry)
            else:
                moved = backup.save(os.path.expanduser(self.file))
                if not dry:
                    shutil.copyfile(rec["original_backup"], os.path.realpath(os.path.expanduser(self.file)))
            report.append("%s: put back the original %s (the installed copy went to %s)"
                          % (self.path, rec["original_backup"], moved))
        elif rec.get("created_file"):
            if self.io.remote:
                moved = self.io.trash(self.file, dry)
            else:
                moved = backup.move(os.path.expanduser(self.file))
            report.append("%s: the skill it installed moved to %s" % (self.path, moved))
            if rec.get("created_dir"):
                if self.io.remote:
                    d = self.io.trash_dir_if_empty(rec["created_dir"], dry)
                else:
                    d = None
                    real = os.path.expanduser(rec["created_dir"])
                    if not dry and os.path.isdir(real) and not os.listdir(real):
                        d = backup.move(real)
                if d:
                    report.append("%s: the empty folder it created moved to %s" % (self.path, d))
        state.pop(self.path, None)

    def verify(self):
        if self.io.remote and not PROBED.get(self.io.host):
            return "skipped (no ssh)"
        have = self.io.read(self.file)
        if have is None:
            return "missing"
        return "ok (skill matches the repo)" if have == self.source() else "differs from the repo copy"


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
    def __init__(self, path, make, extra, io=LOCAL, refresh=False):
        self.io = io
        self.file = path
        self.path = io.label(path)
        self.make = make    # (script, env) -> (command, args, env for an `env =` line)
        self.extra = extra  # (name, env) -> list of extra lines
        self.refresh = refresh  # rewrite its own blocks when what it would write now differs

    def refresh_own(self, text, names, report):
        """Brings the blocks this script wrote itself (between its markers, for names in its
        state file) up to what it would write now. Every other line is left as it is."""
        for name, script, env in servers():
            if name not in names:
                continue
            m = self.own_block_re(name).search(text)
            if not m:
                continue
            want = self.block(name, script, env).rstrip("\n")
            if m.group(0) == want:
                continue
            text = text[:m.start()] + want + text[m.end():]
            report.append("%s: %s brought up to date" % (self.path, name))
        return text

    def block(self, name, script, env):
        command, args, benv = self.make(script, env)
        lines = [MARK_BEGIN.format(name=name), "[mcp_servers.%s]" % name,
                 "command = %s" % toml_str(command), "args = [%s]" % ", ".join(toml_str(a) for a in args)]
        if benv:
            lines.append("env = %s" % toml_inline(benv))
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
        if not self.io.available(report):
            return
        text = self.io.read(self.file)
        existed = text is not None
        if not existed and not self.io.may_create(self.file):
            report.append("%s: missing, and so is its folder; left alone" % self.path)
            return
        if text is None:
            text = ""
        prev = record_of(state, self.path)
        updated = self.update_env_vars(text, prev["names"], report)
        if self.refresh:
            updated = self.refresh_own(updated, prev["names"], report)
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
        saved = None
        if existed:
            saved = self.io.backup(self.file, backup, dry)
            report.append("%s: backed up to %s" % (self.path, saved))
        self.io.write(self.file, new, dry)
        if add or (self.io.remote and prev["names"]):
            rec = {"names": sorted(set(prev["names"]) | {n for n, _ in add}), "created_key": False, "was_empty": False}
            state[self.path] = mac_record(self.io, prev, rec, text if existed else None, saved, new)
        if add:
            report.append("%s: added %s%s" % (self.path, ", ".join(n for n, _ in add), "" if existed else " (new file)"))

    def unregister(self, state, backup, dry, report):
        rec = record_of(state, self.path)
        names = rec["names"]
        if not names or not self.io.available(report):
            return
        text = self.io.read(self.file)
        if text is None:
            state.pop(self.path, None)
            return
        if restore_original(self, rec, text, dry, report):
            state.pop(self.path, None)
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
            if rec["created_file"] and not new.strip():
                report.append("%s: removed %s; the file it created moved to %s"
                              % (self.path, ", ".join(removed), self.io.trash(self.file, dry)))
            else:
                report.append("%s: backed up to %s" % (self.path, self.io.backup(self.file, backup, dry)))
                self.io.write(self.file, new, dry)
                report.append("%s: removed %s" % (self.path, ", ".join(removed)))
        state.pop(self.path, None)

    def verify(self):
        if self.io.remote and not PROBED.get(self.io.host):
            return "skipped (no ssh)"
        text = self.io.read(self.file)
        if text is None:
            return "missing"
        data = toml_parse(text)
        if data is None:
            return "unchecked (no TOML parser)"
        return "ok (mcp_servers: %s)" % (", ".join(sorted(data.get("mcp_servers", {}))) or "none")


# ---------------------------------------------------------------- targets

def codex_extra(name, env):
    # Codex hands MCP servers only a short list of variables; forward the Happy
    # session so the bridge (and the vault) know which chat they serve, and the
    # parent session of a fork or side chat so its browser starts with the
    # parent's login.
    return ['env_vars = ["HAPPY_SESSION_ID", "HAPPY_FORKED_FROM_SESSION_ID"]', "startup_timeout_sec = 20", "tool_timeout_sec = 600"]


def remote_codex_extra(name, env):
    # The wrapper reads all three, so Codex has to hand all three over.
    return ["env_vars = [%s]" % ", ".join(toml_str(v) for v in SESSION_VARS), "startup_timeout_sec = 20", "tool_timeout_sec = 600"]


def agent_extra(name, env):
    # Happy Agent caps tool_timeout_sec at 600.
    return ["enabled = true", "startup_timeout_sec = 20", "tool_timeout_sec = 600"]


def remote_target(io, harness):
    """One Mac harness config, its entries running the servers on prep-ml."""
    sh = "/bin/sh"
    if harness == "claude":
        return JsonTarget("~/.claude.json", "mcpServers", lambda s, env: {
            "type": "stdio", "command": sh, "args": remote_argv(s, {}), "env": {}}, io)
    if harness == "gemini":
        return JsonTarget("~/.gemini/settings.json", "mcpServers", lambda s, env: {
            "command": sh, "args": remote_argv(s, env), "env": {}, "timeout": 600000}, io, create_with="gemini")
    if harness == "antigravity":
        # prep-pro links this to ~/.gemini/config/mcp_config.json; writes go through the link.
        return JsonTarget("~/.gemini/antigravity/mcp_config.json", "mcpServers", lambda s, env: {
            "command": sh, "args": remote_argv(s, env), "env": {}}, io)
    if harness == "opencode":
        return OpencodeTarget(lambda s, env: {
            "type": "local", "command": [sh] + remote_argv(s, env), "enabled": True}, io)
    if harness == "codex":
        # refresh: a wrapper it wrote before (without BRIDGE_PUBLIC_BASE, say) is rewritten.
        return TomlTarget("~/.codex/config.toml", lambda s, env: (sh, remote_argv(s, env), {}), remote_codex_extra, io, refresh=True)
    if harness == "happy-agent":
        return TomlTarget("~/.local/share/happy-agent/happy/config/mcp.toml",
                          lambda s, env: (sh, remote_argv(s, agent_env(s, env, io.host)), {}), agent_extra, io, refresh=True)
    raise ValueError("unknown harness %s" % harness)


def targets(remote=True):
    out = [
        TomlTarget("~/.codex/config.toml", lambda s, env: (HOST_NODE, [s], env), codex_extra),
        JsonTarget("~/.gemini/settings.json", "mcpServers", lambda s, env: {
            "command": HOST_NODE, "args": [s], "env": dict(env), "timeout": 600000}),
        JsonTarget("~/.gemini/config/mcp_config.json", "mcpServers", lambda s, env: {
            "command": HOST_NODE, "args": [s], "env": dict(env)}),
        JsonTarget("~/.claude.json", "mcpServers", lambda s, env: {
            "type": "stdio", "command": "node", "args": [s], "env": {}}),
        TomlTarget("~/.local/share/happy-agent/happy/config/mcp.toml", lambda s, env: (AGENT_NODE, [s], agent_env(s, env)), agent_extra, refresh=True),
        SkillTarget(),
    ]
    if remote:
        for host, harnesses in REMOTES:
            io = RemoteIO(host)
            out += [remote_target(io, h) for h in harnesses]
            out.append(SkillTarget(io))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("action", choices=["register", "unregister", "check"])
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--no-remote", action="store_true", help="leave the Macs alone")
    a = ap.parse_args()

    if not os.path.isfile(BRIDGE):
        sys.exit("no bridge at %s" % BRIDGE)
    state = load_state()
    backup = Backup(a.dry_run)
    report = []
    failed = False
    all_targets = targets(remote=not a.no_remote)
    for t in all_targets:
        try:
            if a.action == "register":
                t.register(state, backup, a.dry_run, report)
            elif a.action == "unregister":
                t.unregister(state, backup, a.dry_run, report)
            elif t.io.remote:
                t.io.available(report)
        except Exception as e:  # noqa: BLE001
            failed = True
            report.append("%s: FAILED: %s" % (t.path, e))
    save_state(state, a.dry_run)
    if a.dry_run:
        report.insert(0, "dry run: nothing written")
    print("\n".join(report))
    print("\nparse check:")
    for t in all_targets:
        try:
            print("  %-60s %s" % (t.path, t.verify()))
        except Exception as e:  # noqa: BLE001
            failed = True
            print("  %-60s DOES NOT PARSE: %s" % (t.path, e))
    if a.action != "check":
        print("\nRestart to pick these up: new Codex, Gemini, opencode, agy and Claude sessions read them at start;"
              "\nHappy Agent reloads mcp.toml without a daemon restart (or restart happy-agent); Antigravity: reload its MCP servers.")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
