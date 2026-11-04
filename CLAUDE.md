@AGENTS.md

- In an agent run dir use `./bin/ham-ctl`; read `TASK.md` on wake and work only in the Workdir it names.
- Present the hub-returned `preview_url` to the user, never a `localhost` URL.
- Reply to the user with `ham-ctl chat send --to user`; terminal output is not delivered.
- Run builds/tests through `ham-ctl shell run --cwd <workdir>` and report exact commands and outcomes.
