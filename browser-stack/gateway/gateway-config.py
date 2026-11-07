#!/usr/bin/env python3
"""Keep the browser stack's part of the host agentgateway config up to date.

Use through make (browser-stack/Makefile):
  make gateway-config          show what would change (nothing is written)
  make gateway-config WRITE=1  back the config up, then write it in place
  make gateway-keys            make a key for each Mac that has none

agentgateway (systemd unit agentgateway.service, running as this user) reads
/home/prep/coder/agentgateway/config.yaml and reloads it on change, except its
top-level `config:` section. This script owns three marked pieces of it and
leaves everything else as it is:

  gateways.lan     a second gateway on the LAN address (LAN_BIND:LAN_PORT).
                   Every request on it needs a Mac's own API key
                   (Authorization: Bearer <key>, removed before forwarding)
                   AND has to come from that Mac's address. Nothing else on the
                   network, prep-ml itself included, gets in.
  llm.gateways     the coder LLM API on both gateways, so a Mac reaches the
                   same models with its key.
  routes           /browser/mcp and /vault/mcp, on `lan` only: agentgateway
                   starts the bridge's and the vault's stdio MCP servers itself
                   (one per MCP session) with BROWSER_CHAT_FROM_META=1, so they
                   take the chat from the _meta the Mac's client stamps on each
                   call (client/mcp-gateway-client.mjs). Never on `default`:
                   Caddy's public /coder/* goes to the default gateway.

agentgateway can not put one port on two addresses (127.0.0.1:8903 already is
the default gateway), so the LAN listener is 192.168.2.72:8904.

The Macs' keys live in ~/.config/browser-stack/gateway-keys/<mac> (mode 600,
made by `make gateway-keys`); they are written into the config and nowhere
else, and never printed. Before every write the current config is copied to
/home/prep/happy-trash/<ts>_agentgateway-config/ (mode 600).
"""

import argparse
import difflib
import os
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import time

CONFIG = os.environ.get("AGENTGATEWAY_CONFIG", "/home/prep/coder/agentgateway/config.yaml")
AGW = os.environ.get("AGENTGATEWAY_BIN", "/usr/local/bin/agentgateway")
KEYS = os.path.expanduser(os.environ.get("BROWSER_STACK_GATEWAY_KEYS", "~/.config/browser-stack/gateway-keys"))
TRASH = os.environ.get("BROWSER_STACK_TRASH", "/home/prep/happy-trash")
LAN_BIND = os.environ.get("BROWSER_STACK_LAN_BIND", "192.168.2.72")
LAN_PORT = int(os.environ.get("BROWSER_STACK_LAN_PORT", "8904"))
HERE = os.path.dirname(os.path.abspath(__file__))
STACK = os.path.dirname(HERE)
NODE = os.environ.get("BROWSER_STACK_NODE") or shutil.which("node") or "/usr/bin/node"
# Where a Mac opens the bridge's live pages (its LAN listener, BRIDGE_LAN_BIND).
LINK_BASE = os.environ.get("BROWSER_STACK_LINK_BASE", "http://%s:6090" % LAN_BIND)
# browser_wait_for_human returns inside the harnesses' 600 s tool limit.
WAIT_MAX_S = "570"

# Each Mac: its address on the LAN. A key works only from that address.
MACS = [
    ("prep-air", "192.168.2.56"),
    ("prep-pro", "192.168.2.55"),
]

MAC_NAME = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
IPV4 = re.compile(r"^(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}$")
KEY = re.compile(r"^[0-9a-f]{64}$")

LAN_BEGIN = "  # >>> browser-stack: lan gateway"
LAN_END = "  # <<< browser-stack: lan gateway"
ROUTES_BEGIN = "  # >>> browser-stack: routes"
ROUTES_END = "  # <<< browser-stack: routes"
LLM_LINE = "  gateways: [default, lan]  # browser-stack: the coder API on the LAN gateway too"


def script_paths():
    """The two stdio MCP servers, wherever this checkout keeps them."""
    for bridge, vault in [
        (os.path.join(STACK, "browser/bridge/mcp.mjs"), os.path.join(STACK, "vault-mcp/mcp.mjs")),
        (os.path.join(STACK, "..", "selfhost/browser/bridge/mcp.mjs"), os.path.join(STACK, "..", "selfhost/vault-mcp/mcp.mjs")),
    ]:
        if os.path.isfile(bridge):
            return os.path.normpath(bridge), os.path.normpath(vault)
    sys.exit("no bridge MCP server found under %s" % STACK)


def read_keys(required=True):
    keys = {}
    for mac, ip in MACS:
        if not MAC_NAME.match(mac) or not IPV4.match(ip):
            sys.exit("bad Mac entry %r" % mac)
        path = os.path.join(KEYS, mac)
        try:
            st = os.stat(path)
            with open(path) as f:
                k = f.read().strip()
        except FileNotFoundError:
            if required:
                sys.exit("no key for %s at %s (make gateway-keys)" % (mac, path))
            continue
        if st.st_mode & 0o077:
            sys.exit("%s is readable by others; chmod 600 it" % path)
        if not KEY.match(k):
            sys.exit("%s is not a 64-hex-digit key" % path)
        keys[mac] = k
    return keys


def make_keys():
    os.makedirs(KEYS, mode=0o700, exist_ok=True)
    os.chmod(KEYS, 0o700)
    for mac, _ in MACS:
        path = os.path.join(KEYS, mac)
        if os.path.exists(path):
            print("%s: has a key" % mac)
            continue
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(secrets.token_hex(32) + "\n")
        print("%s: key made at %s" % (mac, path))


def q(s):
    """A YAML double-quoted string (only plain characters ever reach here)."""
    if not re.match(r"^[A-Za-z0-9_./:@ -]*$", s):
        raise ValueError("unexpected character in %r" % s)
    return '"%s"' % s


def lan_block(keys):
    lines = [LAN_BEGIN + " (browser-stack/gateway/gateway-config.py; edit there)",
             "  lan:",
             "    port: %d" % LAN_PORT,
             "    bindAddress: %s" % q(LAN_BIND),
             "    apiKey:",
             "      mode: strict",
             "      keys:"]
    for mac, _ in MACS:
        lines += ["        - key: %s" % q(keys[mac]),
                  "          metadata: {mac: %s}" % q(mac)]
    rule = " || ".join('(source.address == "%s" && apiKey.mac == "%s")' % (ip, mac) for mac, ip in MACS)
    lines += ["    # A Mac's key, from that Mac's address. Anything else is refused.",
              "    authorization:",
              "      rules:",
              "        - require: '%s'" % rule,
              LAN_END]
    return "\n".join(lines) + "\n"


def mcp_route(name, prefix, target, cmd, args, env):
    lines = ["  - name: %s" % name,
             "    gateways: [lan]",
             "    matches:",
             "      - path:",
             "          pathPrefix: %s" % prefix,
             "    policies:",
             "      # browser_wait_for_human holds a call open for up to %s s." % WAIT_MAX_S,
             "      timeout:",
             "        requestTimeout: 900s",
             "    backends:",
             "      - mcp:",
             "          statefulMode: stateful",
             "          targets:",
             "            - name: %s" % target,
             "              stdio:",
             "                cmd: %s" % q(cmd),
             "                args: [%s]" % ", ".join(q(a) for a in args),
             "                env:"]
    for k, v in sorted(env.items()):
        lines.append("                  %s: %s" % (k, q(v)))
    return lines


def routes_block(routes):
    bridge, vault = script_paths()
    lines = [ROUTES_BEGIN + " (browser-stack/gateway/gateway-config.py; edit there)",
             "  # The browser bridge's and the vault's MCP servers, LAN gateway only. Each call's chat",
             "  # comes from the _meta the Mac's client stamps (BROWSER_CHAT_FROM_META=1), never from",
             "  # tool arguments."]
    if "browser" in routes:
        lines += mcp_route("browser-mcp", "/browser", "browser", NODE, [bridge], {
            "BROWSER_CHAT_FROM_META": "1",
            "BRIDGE_WAIT_MAX_S": WAIT_MAX_S,
            "BRIDGE_PUBLIC_BASE": LINK_BASE,
        })
    if "vault" in routes and os.path.isfile(vault):
        lines += mcp_route("vault-mcp", "/vault", "vault", NODE, [vault], {"BROWSER_CHAT_FROM_META": "1"})
    if "test" in routes:
        lines += mcp_route("gateway-test-mcp", "/gwtest", "gwtest", NODE,
                           [os.path.join(HERE, "test/slow-mcp.mjs")], {"BROWSER_CHAT_FROM_META": "1"})
    lines.append(ROUTES_END)
    return "\n".join(lines) + "\n"


def strip_block(text, begin, end):
    pat = re.compile("^" + re.escape(begin) + r".*?^" + re.escape(end) + r"\n", re.S | re.M)
    return pat.sub("", text)


def render(text, keys, routes):
    text = strip_block(text, LAN_BEGIN, LAN_END)
    text = strip_block(text, ROUTES_BEGIN, ROUTES_END)
    text = text.replace(LLM_LINE + "\n", "")
    # gateways.lan right after gateways.default (the first two-space key under gateways:).
    m = re.search(r"^gateways:\n((?:[ #].*\n|\n)*?)(?=^\S)", text, re.M)
    if not m:
        sys.exit("no top-level gateways: in %s" % CONFIG)
    body = m.group(1).rstrip("\n") + "\n"
    text = text[:m.start(1)] + body + lan_block(keys) + "\n" + text[m.end(1):]
    # llm attaches to both gateways.
    if not re.search(r"^llm:\n", text, re.M):
        sys.exit("no top-level llm: in %s" % CONFIG)
    if re.search(r"^llm:\n(?:[ #].*\n)*?  gateways:", text, re.M):
        sys.exit("llm: already names gateways; set it by hand")
    text = re.sub(r"^llm:\n", "llm:\n" + LLM_LINE + "\n", text, count=1, flags=re.M)
    # routes: our items at the end of the top-level routes: list.
    m = re.search(r"^routes:\n((?:[ #].*\n|\n)*?)(?=^\S)", text, re.M)
    if not m:
        sys.exit("no top-level routes: in %s (followed by another section)" % CONFIG)
    body = m.group(1).rstrip("\n") + "\n"
    text = text[:m.start(1)] + body + routes_block(routes) + "\n" + text[m.end(1):]
    return text


def redact(text):
    return re.sub(r'(- key: )"[0-9a-f]{64}"', r'\1"<key>"', text)


def validate(text):
    """agentgateway --validate-only on a private copy next to the config's own files."""
    folder = os.path.dirname(CONFIG)
    with tempfile.TemporaryDirectory(prefix="agw-validate-") as tmp:
        os.chmod(tmp, 0o700)
        for name in os.listdir(folder):
            p = os.path.join(folder, name)
            if os.path.isfile(p) and p != CONFIG and not name.startswith("."):
                shutil.copy2(p, tmp)
        path = os.path.join(tmp, "config.yaml")
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(text)
        r = subprocess.run([AGW, "--validate-only", "-f", path], capture_output=True, text=True, cwd=tmp)
        out = redact((r.stdout + r.stderr).strip())
    return r.returncode == 0, out


def backup():
    ts = time.strftime("%Y%m%d_%H%M%S")
    d = os.path.join(TRASH, ts + "_agentgateway-config")
    os.makedirs(d, mode=0o700, exist_ok=True)
    dest = os.path.join(d, "config.yaml")
    shutil.copy2(CONFIG, dest)
    os.chmod(dest, 0o600)
    with open(os.path.join(d, "README"), "a") as f:
        f.write("Copy of %s before browser-stack/gateway/gateway-config.py rewrote it (%s).\n"
                "Restore: cp -p %s %s (agentgateway reloads it on change).\n" % (CONFIG, ts, dest, CONFIG))
    return dest


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("action", choices=["show", "write", "keys"])
    ap.add_argument("--routes", default="browser,vault", help="comma list of browser,vault,test (default browser,vault)")
    a = ap.parse_args()
    if a.action == "keys":
        return make_keys()
    routes = set(filter(None, a.routes.split(",")))
    if routes - {"browser", "vault", "test"}:
        sys.exit("unknown route in --routes")
    with open(CONFIG) as f:
        old = f.read()
    keys = read_keys()
    new = render(old, keys, routes)
    ok, out = validate(new)
    diff = list(difflib.unified_diff(redact(old).splitlines(), redact(new).splitlines(), CONFIG, CONFIG + " (new)", lineterm=""))
    print("\n".join(diff) if diff else "no change")
    print("validate: %s" % out)
    if not ok:
        sys.exit(1)
    if a.action == "write" and new != old:
        if os.stat(CONFIG).st_mode & 0o077:
            os.chmod(CONFIG, 0o600)
        print("backed up to %s" % backup())
        # In place (same file, same mode): agentgateway watches this path.
        with open(CONFIG, "r+") as f:
            f.write(new)
            f.truncate()
        print("written; agentgateway reloads it on its own")


if __name__ == "__main__":
    main()
