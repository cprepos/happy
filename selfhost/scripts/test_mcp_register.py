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


if __name__ == "__main__":
    unittest.main()
