"""Read-only native plugin/hook inventory for a prepared fixture home."""
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import time

def main():
    root = Path(sys.argv[1]).resolve()
    marketplace = Path(sys.argv[2]).resolve()
    env = {k: os.environ[k] for k in ("PATH", "TERM") if k in os.environ}
    env.update(HOME=str(root / "user"), CODEX_HOME=str(root / "home"))
    p = subprocess.Popen([os.environ.get("CODEX_BIN", "codex"), "app-server"],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, text=True, env=env, cwd=root/"workspace")
    def call(number, method, params):
        p.stdin.write(json.dumps({"id":number,"method":method,"params":params})+"\n")
        p.stdin.flush()
        deadline = time.monotonic()+10
        while time.monotonic() < deadline:
            if not select.select([p.stdout], [], [], .25)[0]:
                continue
            d = json.loads(p.stdout.readline())
            if d.get("id") == number:
                return d
        raise TimeoutError(method)
    try:
        call(1, "initialize", {"clientInfo":{"name":"heimdall-fixtures","version":"0.1.0"},
                               "capabilities":{"experimentalApi":True}})
        p.stdin.write('{"method":"initialized"}\n'); p.stdin.flush()
        plugin = call(2,"plugin/read",{"pluginName":"heimdall","marketplacePath":str(marketplace)})
        detail = plugin.get("result",{}).get("plugin",{})
        print(json.dumps({"plugin_hooks":detail.get("hooks"),"error":plugin.get("error")}))
        hooks = call(3,"hooks/list",{"cwds":[str(root/"workspace")]})
        for group in hooks.get("result",{}).get("data",[]):
            print(json.dumps({"hooks":[{"plugin":h.get("pluginId"),"event":h.get("eventName"),
                                       "trust":h.get("trustStatus")} for h in group.get("hooks",[])],
                              "errors":group.get("errors")}))
    finally:
        p.terminate()
        p.wait(timeout=5)

if __name__ == "__main__":
    main()
