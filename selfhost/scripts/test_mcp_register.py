"""mcp-register in a scratch home folder: never the real one.

Run through make: `make -C selfhost mcp-register-test`.
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mcp-register.py")
WANT = ["HAPPY_SESSION_ID", "HAPPY_FORKED_FROM_SESSION_ID"]

try:
    import tomllib as toml
except ImportError:  # Python < 3.11
    import tomli as toml


def old_block(name, script, env_vars='["HAPPY_SESSION_ID"]'):
    return ("# >>> happy mcp-register: {n}\n[mcp_servers.{n}]\ncommand = \"/usr/bin/node\"\n"
            "args = [\"{s}\"]\nenv_vars = {e}\nstartup_timeout_sec = 20\ntool_timeout_sec = 600\n"
            "# <<< happy mcp-register: {n}\n").format(n=name, s=script, e=env_vars)


class McpRegisterTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="mcp-register-test-")
        self.home = self.tmp.name
        self.trash = os.path.join(self.home, "trash")
        self.codex = os.path.join(self.home, ".codex", "config.toml")
        self.state = os.path.join(self.home, ".local/share/happy-mcp-register/state.json")
        os.makedirs(os.path.dirname(self.codex))

    def tearDown(self):
        self.tmp.cleanup()

    def run_register(self, *extra):
        env = dict(os.environ, HOME=self.home, HAPPY_MCP_REGISTER_TRASH=self.trash)
        r = subprocess.run([sys.executable, SCRIPT, "register", "--no-remote", *extra], env=env,
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertTrue(os.path.realpath(self.home) != os.path.realpath(os.path.expanduser("~")))
        return r.stdout

    def codex_servers(self):
        with open(self.codex, "rb") as f:
            return toml.load(f)["mcp_servers"]

    def backups(self):
        if not os.path.isdir(self.trash):
            return []
        return [os.path.join(d, f) for d in [os.path.join(self.trash, x) for x in os.listdir(self.trash)]
                for f in os.listdir(d) if f.endswith("config.toml")]

    def test_fresh_entries_forward_both_variables(self):
        open(self.codex, "w").close()
        self.run_register()
        servers = self.codex_servers()
        self.assertIn("happy-browser-bridge", servers)
        for name, s in servers.items():
            self.assertEqual(s["env_vars"], WANT, name)

    def test_own_entries_gain_missing_names_and_nothing_else_changes(self):
        bridge = "/home/prep/happy/selfhost/browser/bridge/mcp.mjs"
        vault = "/home/prep/happy/selfhost/vault-mcp/mcp.mjs"
        user = ('# my settings\nmodel = "x"\n\n[mcp_servers.other]\ncommand = "o"\n'
                'env_vars = ["HAPPY_SESSION_ID"]\n')
        names = ["happy-browser-bridge"] + (["vault"] if os.path.isfile(vault) else [])
        text = user + "\n" + "\n".join(old_block(n, bridge if n == "happy-browser-bridge" else vault) for n in names)
        with open(self.codex, "w") as f:
            f.write(text)
        os.makedirs(os.path.dirname(self.state))
        with open(self.state, "w") as f:
            json.dump({self.codex: {"names": names, "created_key": False, "was_empty": False}}, f)

        # A dry run says what it would do and writes nothing.
        out = self.run_register("--dry-run")
        self.assertIn("env_vars added HAPPY_FORKED_FROM_SESSION_ID", out)
        with open(self.codex) as f:
            self.assertEqual(f.read(), text)
        self.assertEqual(self.backups(), [])

        self.run_register()
        servers = self.codex_servers()
        for n in names:
            self.assertEqual(servers[n]["env_vars"], WANT, n)
            self.assertEqual(servers[n]["tool_timeout_sec"], 600)
        self.assertEqual(servers["other"]["env_vars"], ["HAPPY_SESSION_ID"], "an entry it did not write is left alone")
        with open(self.codex) as f:
            after = f.read()
        self.assertTrue(after.startswith(user), "the rest of the file is kept")
        self.assertEqual(after.count("# >>> happy mcp-register:"), len(names), "nothing added twice")
        self.assertEqual(len(self.backups()), 1, "the original went to trash first")
        with open(self.backups()[0]) as f:
            self.assertEqual(f.read(), text)

        # Again: nothing to do, nothing written, no new backup.
        out = self.run_register()
        self.assertNotIn("env_vars added", out)
        with open(self.codex) as f:
            self.assertEqual(f.read(), after)
        self.assertEqual(len(self.backups()), 1)

    def test_unrecorded_marked_entry_is_not_updated(self):
        bridge = "/home/prep/happy/selfhost/browser/bridge/mcp.mjs"
        text = old_block("happy-browser-bridge", bridge)
        with open(self.codex, "w") as f:
            f.write(text)
        out = self.run_register()  # no state file: the entry is not one it recorded
        self.assertNotIn("happy-browser-bridge env_vars added", out)
        self.assertEqual(self.codex_servers()["happy-browser-bridge"]["env_vars"], ["HAPPY_SESSION_ID"])


def load_module():
    """mcp-register.py as a module (for remote_wrapper); importing it writes nothing."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("mcp_register", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# A stand-in for ssh: `ssh [-o x]... <host> <command...>` runs the joined command
# with /bin/sh (as sshd hands it to the remote shell) in $FAKE_SSH_ROOT/<host> as HOME.
# Hosts without a folder there answer like an unreachable host (exit 255).
FAKE_SSH = """#!%s
import os, subprocess, sys
args = sys.argv[1:]
i = 0
while i < len(args) and args[i].startswith("-"):
    i += 2 if args[i] in ("-o", "-p", "-i", "-l") else 1
host, cmd = args[i], " ".join(args[i + 1:])
home = os.path.join(os.environ["FAKE_SSH_ROOT"], host)
if not os.path.isdir(home):
    sys.exit(255)
with open(os.path.join(os.environ["FAKE_SSH_ROOT"], "calls.log"), "a") as f:
    f.write(host + "\\n")
sys.exit(subprocess.call(["/bin/sh", "-c", cmd], env=dict(os.environ, HOME=home), cwd=home))
""" % sys.executable


class Scratch(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="mcp_register_test_")
        self.root = self.tmp.name
        self.home = os.path.join(self.root, "home")
        self.macs = os.path.join(self.root, "macs")
        self.bin = os.path.join(self.root, "bin")
        for d in (self.home, self.macs, self.bin, os.path.join(self.macs, "prep-ml")):
            os.makedirs(d)
        self.ssh = os.path.join(self.bin, "ssh")
        with open(self.ssh, "w") as f:
            f.write(FAKE_SSH)
        os.chmod(self.ssh, 0o755)
        self.assertNotEqual(os.path.realpath(self.home), os.path.realpath(os.path.expanduser("~")))

    def tearDown(self):
        self.tmp.cleanup()

    def env(self, **extra):
        return dict(os.environ, HOME=self.home, HAPPY_MCP_REGISTER_TRASH=os.path.join(self.root, "trash"),
                    FAKE_SSH_ROOT=self.macs, PATH=self.bin + os.pathsep + os.environ.get("PATH", ""), **extra)


class RemoteWrapperTest(Scratch):
    """The wrapper's id check, run for real: /bin/sh here, the fake ssh, /bin/sh "on prep-ml"."""

    VALID = ["test-d-verify", "A_b-9", "x" * 128, "0b1f9c2e-6a7d-4c1e-9b2a-3f4e5d6c7b8a"]
    BAD = ["$(touch {c})", "`touch {c}`", "a;touch {c}", "a && touch {c}", "a|touch {c}", "a b",
           "a'b", 'a"b', "a\\nb", "a\\\\b", "a\ntouch {c}", "x" * 129, "../etc", "a/b", "a=b",
           "été", "аbc", "a*", "${{IFS}}touch${{IFS}}{c}", "a\tb", "~", "a b'; touch {c}; '"]

    def wrap(self):
        m = load_module()
        # The remote "node" and script are both /usr/bin/env, so "prep-ml" prints its environment.
        return m, m.remote_wrapper("/usr/bin/env", {"BRIDGE_WAIT_MAX_S": "570"}, ssh=self.ssh, hop="prep-ml", node="/usr/bin/env")

    def remote_env(self, wrapper, **ids):
        env = {k: v for k, v in self.env().items() if not k.startswith(("HAPPY_", "CLAUDE_"))}
        env.update(ids)
        r = subprocess.run(["/bin/sh", "-c", wrapper], env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 0, r.stderr)
        return dict(line.split("=", 1) for line in r.stdout.splitlines() if "=" in line)

    def test_injection_strings_are_blanked(self):
        m, w = self.wrap()
        canary = os.path.join(self.root, "pwned")
        for raw in self.BAD:
            bad = raw.format(c=canary)
            for var in m.SESSION_VARS:
                with self.subTest(var=var, value=bad):
                    got = self.remote_env(w, **{var: bad})
                    self.assertEqual(got.get(var), "", "the value is sent blank")
                    self.assertFalse(os.path.exists(canary), "nothing ran")
        self.assertFalse(os.path.exists(canary))

    def test_valid_ids_are_kept(self):
        m, w = self.wrap()
        for good in self.VALID:
            with self.subTest(value=good):
                got = self.remote_env(w, HAPPY_SESSION_ID=good, CLAUDE_CODE_SESSION_ID=good, HAPPY_FORKED_FROM_SESSION_ID=good)
                for var in m.SESSION_VARS:
                    self.assertEqual(got[var], good)
                self.assertEqual(got["BRIDGE_WAIT_MAX_S"], "570")

    def test_one_bad_id_does_not_blank_the_others(self):
        m, w = self.wrap()
        got = self.remote_env(w, HAPPY_SESSION_ID="good-1", CLAUDE_CODE_SESSION_ID="$(id)", HAPPY_FORKED_FROM_SESSION_ID="parent_2")
        self.assertEqual((got["HAPPY_SESSION_ID"], got["CLAUDE_CODE_SESSION_ID"], got["HAPPY_FORKED_FROM_SESSION_ID"]),
                         ("good-1", "", "parent_2"))

    def test_unset_ids_go_blank(self):
        m, w = self.wrap()
        got = self.remote_env(w)
        for var in m.SESSION_VARS:
            self.assertEqual(got[var], "")

    def test_the_real_wrapper_uses_absolute_ssh_and_node(self):
        m = load_module()
        w = m.remote_wrapper(m.BRIDGE, m.WAIT)
        self.assertIn("exec /usr/bin/ssh -o BatchMode=yes -o LogLevel=ERROR prep-ml ", w)
        self.assertTrue(w.endswith(" /usr/bin/node " + m.BRIDGE))

    def test_unsafe_fixed_words_are_refused(self):
        m = load_module()
        for script in ("/a b/mcp.mjs", "/x;rm/mcp.mjs", "$(x)"):
            with self.assertRaises(ValueError):
                m.remote_wrapper(script, {})
        with self.assertRaises(ValueError):
            m.remote_wrapper("/ok.mjs", {"K": "a b"})


class RemoteRoundTripTest(Scratch):
    """register then unregister with the Macs on (fake ssh): every Mac file ends as it began."""

    BRIDGE = "/home/prep/happy/selfhost/browser/bridge/mcp.mjs"
    VAULT = "/home/prep/happy/selfhost/vault-mcp/mcp.mjs"

    def put(self, host, rel, text):
        p = os.path.join(self.macs, host, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write(text)
        return p

    def read(self, host, rel):
        with open(os.path.join(self.macs, host, rel)) as f:
            return f.read()

    def run_script(self, action, *extra):
        r = subprocess.run([sys.executable, SCRIPT, action, *extra], env=self.env(),
                           capture_output=True, text=True, timeout=120)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        return r.stdout

    def setUp(self):
        super().setUp()
        self.names = ["happy-browser-bridge"] + (["vault"] if os.path.isfile(self.VAULT) else [])
        old_agy = {"mcpServers": {n: {"command": "ssh", "args": ["-o", "BatchMode=yes", "prep-ml", "/usr/bin/node",
                                                                  self.BRIDGE if n == "happy-browser-bridge" else self.VAULT],
                                      "env": {}} for n in self.names}}
        self.orig = {
            ("prep-air", ".claude.json"): '{\n  "numStartups": 3,\n  "projects": {"/Users/x": {"a": 1}}\n}\n',
            ("prep-air", ".local/share/happy-agent/happy/config/mcp.toml"): "# agent servers\n",
            ("prep-pro", ".claude.json"): '{\n    "mcpServers": {\n        "mine": {"command": "x"}\n    }\n}\n',
            ("prep-pro", ".codex/config.toml"): 'model = "gpt"\n\n[mcp_servers.node_repl]\ncommand = "node"\n',
            ("prep-pro", ".config/opencode/opencode.json"): '{\n  "mcp": {\n    "searxng": {"type": "local", "command": ["s"]}\n  }\n}\n',
            ("prep-pro", ".gemini/settings.json"): '{\n  "theme": "x"\n}\n',
            ("prep-pro", ".gemini/config/mcp_config.json"): json.dumps(old_agy, indent=2) + "\n",
        }
        for (host, rel), text in self.orig.items():
            self.put(host, rel, text)
        # Antigravity's path on prep-pro is a link to the real file.
        os.makedirs(os.path.join(self.macs, "prep-pro/.gemini/antigravity"))
        os.symlink("../config/mcp_config.json", os.path.join(self.macs, "prep-pro/.gemini/antigravity/mcp_config.json"))
        # prep-pro has a happy-agent folder but no mcp.toml yet: register creates it.
        os.makedirs(os.path.join(self.macs, "prep-pro/.local/share/happy-agent/happy/config"))
        # The plain-ssh Antigravity entries were added by an earlier mcp-register run.
        self.state = os.path.join(self.home, ".local/share/happy-mcp-register/state.json")
        os.makedirs(os.path.dirname(self.state))
        with open(self.state, "w") as f:
            json.dump({"prep-pro:~/.gemini/antigravity/mcp_config.json":
                       {"names": self.names, "created_key": True, "was_empty": True}}, f)

    def mac_trash(self, host):
        d = os.path.join(self.macs, host, "happy-trash")
        return sorted(os.path.join(r, f) for r, _, fs in os.walk(d) for f in fs) if os.path.isdir(d) else []

    def assert_wrapped(self, entry, script):
        argv = ([entry["command"]] + entry.get("args", [])) if isinstance(entry["command"], str) else entry["command"]
        self.assertEqual(argv[:2], ["/bin/sh", "-c"])
        self.assertIn("exec /usr/bin/ssh -o BatchMode=yes -o LogLevel=ERROR prep-ml ", argv[2])
        self.assertTrue(argv[2].endswith(" /usr/bin/node " + script), argv[2])
        for var in ("HAPPY_SESSION_ID", "CLAUDE_CODE_SESSION_ID", "HAPPY_FORKED_FROM_SESSION_ID"):
            self.assertIn('%s="$' % var, argv[2])

    def test_round_trip(self):
        before = {k: self.read(*k) for k in self.orig}
        agent_toml = os.path.join(self.macs, "prep-pro/.local/share/happy-agent/happy/config/mcp.toml")
        link = os.path.join(self.macs, "prep-pro/.gemini/antigravity/mcp_config.json")

        out = self.run_script("register", "--dry-run")
        self.assertIn("dry run: nothing written", out)
        self.assertEqual({k: self.read(*k) for k in self.orig}, before)
        self.assertEqual(self.mac_trash("prep-pro") + self.mac_trash("prep-air"), [])
        self.assertFalse(os.path.exists(agent_toml))

        out = self.run_script("register")
        self.assertIn("prep-air: `ssh -o BatchMode=yes prep-ml true` works", out)
        self.assertIn("prep-air:~/.gemini/settings.json: missing, and so is its folder; left alone", out)
        self.assertFalse(os.path.exists(os.path.join(self.macs, "prep-air/.gemini")))

        scripts = {"happy-browser-bridge": self.BRIDGE, "vault": self.VAULT}
        for host, rel, key in [("prep-air", ".claude.json", "mcpServers"), ("prep-pro", ".claude.json", "mcpServers"),
                               ("prep-pro", ".config/opencode/opencode.json", "mcp"),
                               ("prep-pro", ".gemini/settings.json", "mcpServers"),
                               ("prep-pro", ".gemini/config/mcp_config.json", "mcpServers")]:
            data = json.loads(self.read(host, rel))
            for n in self.names:
                with self.subTest(host=host, file=rel, name=n):
                    self.assert_wrapped(data[key][n], scripts[n])
        self.assertEqual(json.loads(self.read("prep-pro", ".claude.json"))["mcpServers"]["mine"], {"command": "x"})
        self.assertIn("updated %s to the session-keyed wrapper" % ", ".join(self.names), out)
        self.assertTrue(os.path.islink(link))
        for host, rel in [("prep-air", ".local/share/happy-agent/happy/config/mcp.toml"), ("prep-pro", ".codex/config.toml"),
                          ("prep-pro", ".local/share/happy-agent/happy/config/mcp.toml")]:
            servers = toml.loads(self.read(host, rel))["mcp_servers"]
            for n in self.names:
                self.assert_wrapped(servers[n], scripts[n])
        codex = toml.loads(self.read("prep-pro", ".codex/config.toml"))["mcp_servers"]
        self.assertEqual(codex["happy-browser-bridge"]["env_vars"],
                         ["HAPPY_SESSION_ID", "CLAUDE_CODE_SESSION_ID", "HAPPY_FORKED_FROM_SESSION_ID"])
        self.assertIn("node_repl", codex)

        # Each file that existed was copied to that Mac's ~/happy-trash first, unchanged.
        for p in self.mac_trash("prep-air") + self.mac_trash("prep-pro"):
            self.assertRegex(p, r"/happy-trash/\d{8}_\d{6}_mcp-configs/")
        for (host, rel), text in self.orig.items():
            copies = [p for p in self.mac_trash(host) if p.endswith("__" + rel.replace("/", "__"))]
            self.assertEqual(len(copies), 1, (host, rel))
            with open(copies[0]) as f:
                self.assertEqual(f.read(), text)
        with open(self.state) as f:
            st = json.load(f)
        self.assertTrue(st["prep-pro:~/.local/share/happy-agent/happy/config/mcp.toml"]["created_file"])
        self.assertTrue(st["prep-air:~/.claude.json"]["backups"][0].startswith("prep-air:"))

        # Again: nothing to do.
        again = self.run_script("register")
        self.assertNotIn(": added", again)
        self.assertNotIn(": updated", again)

        self.run_script("unregister")
        for (host, rel), text in self.orig.items():
            if rel == ".gemini/config/mcp_config.json":
                continue
            with self.subTest(host=host, file=rel):
                self.assertEqual(self.read(host, rel), text)
        # Antigravity's servers were all ours from the start (an empty file then).
        self.assertEqual(self.read("prep-pro", ".gemini/config/mcp_config.json"), "")
        self.assertTrue(os.path.islink(link))
        # The mcp.toml register created is moved to the Mac's trash, not deleted.
        self.assertFalse(os.path.exists(agent_toml))
        moved = [p for p in self.mac_trash("prep-pro") if p.endswith("happy-agent__happy__config__mcp.toml")]
        self.assertEqual(len(moved), 1)
        with open(self.state) as f:
            self.assertEqual([k for k in json.load(f) if not k.startswith("/")], [])

    def test_a_file_changed_since_register_keeps_the_change(self):
        self.run_script("register")
        p = os.path.join(self.macs, "prep-pro/.claude.json")
        with open(p) as f:
            data = json.load(f)
        data["numStartups"] = 9  # the harness rewrote its file meanwhile
        with open(p, "w") as f:
            json.dump(data, f, indent=4)
        out = self.run_script("unregister")
        self.assertIn("prep-pro:~/.claude.json: removed", out)
        with open(p) as f:
            after = json.load(f)
        self.assertEqual(after, {"mcpServers": {"mine": {"command": "x"}}, "numStartups": 9})
        # prep-air's untouched file comes back byte for byte.
        self.assertEqual(self.read("prep-air", ".claude.json"), self.orig[("prep-air", ".claude.json")])

    def test_unreachable_mac_is_left_alone(self):
        os.rename(os.path.join(self.macs, "prep-air"), os.path.join(self.root, "air-away"))
        out = self.run_script("register")
        self.assertIn("prep-air: `ssh prep-ml true` does not work without a password", out)
        self.assertIn("prep-pro: `ssh -o BatchMode=yes prep-ml true` works", out)

    def test_no_remote_touches_no_mac(self):
        before = {k: self.read(*k) for k in self.orig}
        self.run_script("register", "--no-remote")
        self.assertEqual({k: self.read(*k) for k in self.orig}, before)
        self.assertFalse(os.path.exists(os.path.join(self.macs, "calls.log")))


class JsoncTest(unittest.TestCase):
    def test_comments_and_trailing_commas(self):
        m = load_module()
        text = ('{\n  // a line comment\n  "$schema": "https://opencode.ai/config.json", /* block */\n'
                '  "s": "keeps // and /* inside strings */ and \\" quotes",\n  "a": [1, 2,],\n}\n')
        plain, had = m.strip_jsonc(text)
        self.assertTrue(had)
        self.assertEqual(json.loads(plain), {"$schema": "https://opencode.ai/config.json",
                                             "s": 'keeps // and /* inside strings */ and " quotes', "a": [1, 2]})

    def test_plain_json_has_no_comments(self):
        m = load_module()
        plain, had = m.strip_jsonc('{"$schema": "https://opencode.ai/config.json"}')
        self.assertFalse(had)
        self.assertEqual(json.loads(plain), {"$schema": "https://opencode.ai/config.json"})


class MacHarnessTest(Scratch):
    """prep-air's opencode.jsonc and a Gemini CLI that has not made ~/.gemini yet."""

    BRIDGE = RemoteRoundTripTest.BRIDGE

    put = RemoteRoundTripTest.put
    read = RemoteRoundTripTest.read
    run_script = RemoteRoundTripTest.run_script
    mac_trash = RemoteRoundTripTest.mac_trash

    def setUp(self):
        super().setUp()
        os.makedirs(os.path.join(self.macs, "prep-pro"))
        self.jsonc = '{\n  "$schema": "https://opencode.ai/config.json"\n}\n'
        self.put("prep-air", ".config/opencode/opencode.jsonc", self.jsonc)
        # gemini is installed, but has never run: no ~/.gemini.
        self.put("prep-air", ".local/bin/gemini", "#!/bin/sh\n")
        os.chmod(os.path.join(self.macs, "prep-air/.local/bin/gemini"), 0o755)

    def test_opencode_jsonc_and_new_gemini_folder_round_trip(self):
        out = self.run_script("register")
        self.assertIn("prep-air:~/.config/opencode/opencode.jsonc: added happy-browser-bridge", out)
        self.assertFalse(os.path.exists(os.path.join(self.macs, "prep-air/.config/opencode/opencode.json")),
                         "no second opencode config next to the .jsonc")
        oc = json.loads(self.read("prep-air", ".config/opencode/opencode.jsonc"))
        self.assertEqual(oc["$schema"], "https://opencode.ai/config.json")
        self.assertEqual(oc["mcp"]["happy-browser-bridge"]["command"][:2], ["/bin/sh", "-c"])
        copies = [p for p in self.mac_trash("prep-air") if p.endswith("opencode.jsonc")]
        self.assertEqual(len(copies), 1)
        with open(copies[0]) as f:
            self.assertEqual(f.read(), self.jsonc)

        self.assertIn("prep-air:~/.gemini/settings.json: created ~/.gemini (gemini is installed there)", out)
        gem = json.loads(self.read("prep-air", ".gemini/settings.json"))
        self.assertEqual(list(gem), ["mcpServers"], "only the servers, nothing else")
        self.assertIn("happy-browser-bridge", gem["mcpServers"])

        again = self.run_script("register")
        self.assertNotIn(": added", again)

        self.run_script("unregister")
        self.assertEqual(self.read("prep-air", ".config/opencode/opencode.jsonc"), self.jsonc)
        self.assertFalse(os.path.exists(os.path.join(self.macs, "prep-air/.gemini")),
                         "the file and the empty folder it made went to the trash")
        self.assertTrue([p for p in self.mac_trash("prep-air") if p.endswith(".gemini__settings.json")])

    def test_jsonc_comments_go_but_the_backup_keeps_them(self):
        text = '{\n  // mine\n  "$schema": "https://opencode.ai/config.json",\n  "model": "x",\n}\n'
        self.put("prep-air", ".config/opencode/opencode.jsonc", text)
        out = self.run_script("register")
        self.assertIn("opencode.jsonc: its comments are not kept", out)
        oc = json.loads(self.read("prep-air", ".config/opencode/opencode.jsonc"))
        self.assertEqual(oc["model"], "x")
        copies = [p for p in self.mac_trash("prep-air") if p.endswith("opencode.jsonc")]
        with open(copies[0]) as f:
            self.assertEqual(f.read(), text)

    def test_no_gemini_binary_no_folder(self):
        os.rename(os.path.join(self.macs, "prep-air/.local/bin/gemini"), os.path.join(self.root, "gemini-away"))
        out = self.run_script("register")
        self.assertIn("prep-air:~/.gemini/settings.json: missing, and so is its folder; left alone", out)
        self.assertFalse(os.path.exists(os.path.join(self.macs, "prep-air/.gemini")))


class SkillTest(Scratch):
    """The agent-vault skill: copied from the repo here and to each Mac, and taken back by unregister."""

    run_script = RemoteRoundTripTest.run_script
    mac_trash = RemoteRoundTripTest.mac_trash
    REL = ".claude/skills/agent-vault/SKILL.md"

    def setUp(self):
        super().setUp()
        self.src = load_module().SKILL_SRC
        with open(self.src) as f:
            self.want = f.read()
        for h in ("prep-air", "prep-pro"):
            os.makedirs(os.path.join(self.macs, h, ".claude/skills"))

    def test_the_repo_skill_has_no_secret_material(self):
        self.assertTrue(self.want.startswith("---\nname: agent-vault\n"))
        for pat in (r"[A-Za-z0-9+/=_-]{40,}", r"(?i)(password|token|secret)\s*[:=]\s*\S{6,}", r"\b[A-Z0-9]{10}\b"):
            self.assertNotRegex(self.want, pat)

    def test_local_copy_is_backed_up_replaced_and_put_back(self):
        old = "---\nname: agent-vault\n---\nan older copy\n"
        local = os.path.join(self.home, self.REL)
        os.makedirs(os.path.dirname(local))
        with open(local, "w") as f:
            f.write(old)
        out = self.run_script("register", "--no-remote")
        self.assertIn("installed the agent-vault skill (replaced)", out)
        with open(local) as f:
            self.assertEqual(f.read(), self.want)
        trash = os.path.join(self.root, "trash")
        copies = [os.path.join(r, f) for r, _, fs in os.walk(trash) for f in fs if f.endswith("agent-vault__SKILL.md")]
        self.assertEqual(len(copies), 1)
        with open(copies[0]) as f:
            self.assertEqual(f.read(), old)
        self.assertIn("skill up to date", self.run_script("register", "--no-remote"))
        self.run_script("unregister", "--no-remote")
        with open(local) as f:
            self.assertEqual(f.read(), old)

    def test_macs_get_the_skill_and_unregister_moves_it_to_their_trash(self):
        out = self.run_script("register")
        for h in ("prep-air", "prep-pro"):
            with open(os.path.join(self.macs, h, self.REL)) as f:
                self.assertEqual(f.read(), self.want, h)
            self.assertIn("%s:~/%s: installed the agent-vault skill (new file)" % (h, self.REL), out)
        self.assertIn("skill up to date", self.run_script("register"))
        self.run_script("unregister")
        for h in ("prep-air", "prep-pro"):
            self.assertFalse(os.path.exists(os.path.join(self.macs, h, ".claude/skills/agent-vault")), h)
            self.assertTrue(os.path.isdir(os.path.join(self.macs, h, ".claude/skills")), "only what it made goes")
            moved = [p for p in self.mac_trash(h) if p.endswith("agent-vault__SKILL.md")]
            self.assertEqual(len(moved), 1, h)

    def test_a_mac_copy_edited_after_register_is_left_alone(self):
        self.run_script("register")
        p = os.path.join(self.macs, "prep-pro", self.REL)
        with open(p, "a") as f:
            f.write("a local note\n")
        out = self.run_script("unregister")
        self.assertIn("prep-pro:~/%s: changed since register; left as it is" % self.REL, out)
        self.assertTrue(os.path.exists(p))


if __name__ == "__main__":
    unittest.main()
