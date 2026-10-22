SQLite library: 3.53.3. Scratch DB only; WAL/NORMAL match app/wiring.odin:247-248.
Fixture: 600 shells (30 live; 200 each run/shell/server), 20 bridges, 60 conversations / 6000 messages, 30 chains / 600 tasks / 570 dependencies, 400 tokens (20 unrevoked).
HTTP column is modeled triggers; SQL and VM/fullscan are measured from real procs. Writes = executed DML statements, not disk writes.
| Scenario | HTTP modeled | SELECT | INSERT | UPDATE | DELETE | BEGIN | COMMIT | Writes | VM | Fullscan | Cache hit | Cache miss | Cache page write |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| vault identical touch x30 dedicated conn | 30 | 0 | 0 | 30 | 0 | 0 | 0 | 30 | 1560 | 0 | 87 | 3 | 0 |
| vault changing clock touch x30 | 30 | 0 | 0 | 30 | 0 | 0 | 0 | 30 | 1560 | 0 | 90 | 0 | 30 |
| shell identical registration x92 | 92 | 0 | 92 | 0 | 0 | 0 | 0 | 92 | 13708 | 0 | 823 | 5 | 92 |
| bridge identical save x120 | 0 | 0 | 120 | 0 | 0 | 0 | 0 | 120 | 14040 | 0 | 360 | 0 | 0 |
| bridge heartbeat same state x120 service | 0 | 120 | 120 | 0 | 0 | 0 | 0 | 120 | 18480 | 0 | 720 | 0 | 0 |
| bridge offline repeated x3 service | 0 | 3 | 1 | 0 | 0 | 0 | 0 | 1 | 228 | 0 | 12 | 0 | 1 |
| bridge vault status same x120 service | 0 | 120 | 1 | 0 | 0 | 0 | 0 | 1 | 4557 | 0 | 363 | 0 | 1 |
| bridge heartbeat changing clock x120 service | 0 | 120 | 120 | 0 | 0 | 0 | 0 | 120 | 18480 | 0 | 720 | 0 | 120 |
| conversation read x21 service | 21 | 42 | 21 | 1 | 0 | 0 | 0 | 22 | 27071 | 0 | 1728 | 34 | 104 |
| conversation already read x20 service | 20 | 40 | 20 | 0 | 0 | 0 | 0 | 20 | 17380 | 0 | 967 | 0 | 80 |
| conversation already read changing clock x20 | 20 | 40 | 20 | 0 | 0 | 0 | 0 | 20 | 17380 | 0 | 967 | 0 | 100 |
| mark read same 10 ids x21 service | 21 | 0 | 0 | 21 | 0 | 0 | 0 | 21 | 17522 | 0 | 1588 | 3 | 133 |
| agent already read same 10 ids x20 service | 20 | 0 | 0 | 20 | 0 | 0 | 0 | 20 | 16640 | 0 | 1564 | 0 | 141 |
| task comments x30 service engine no projector | 30 | 30 | 60 | 0 | 0 | 30 | 30 | 60 | 4710 | 0 | 713 | 15 | 300 |
| auth user lookup component x10 | 10 | 10 | 0 | 0 | 0 | 0 | 0 | 0 | 190 | 0 | 28 | 2 | 0 |
| shell owner list component x10 | 10 | 10 | 0 | 0 | 0 | 0 | 0 | 0 | 202660 | 0 | 285 | 25 | 0 |
| card detail component x10 | 10 | 10 | 0 | 0 | 0 | 0 | 0 | 0 | 340 | 0 | 28 | 2 | 0 |
| task detail component x10 | 10 | 10 | 0 | 0 | 0 | 0 | 0 | 0 | 370 | 0 | 50 | 0 | 0 |
| agent identity component x10 | 10 | 10 | 0 | 0 | 0 | 0 | 0 | 0 | 210 | 0 | 28 | 2 | 0 |
| chain list component x10 | 10 | 10 | 0 | 0 | 0 | 0 | 0 | 0 | 14540 | 0 | 28 | 2 | 0 |
| empty search delta enrichment helper x10 | 10 | 20 | 0 | 0 | 0 | 0 | 0 | 0 | 642440 | 0 | 84437 | 273 | 0 |
| conversations x10 pass 0 | 10 | 10 | 0 | 0 | 0 | 0 | 0 | 0 | 487370 | 0 | 84129 | 261 | 0 |
| live bridge ids x10 pass 0 | 0 | 10 | 0 | 0 | 0 | 0 | 0 | 0 | 88440 | 5990 | 470 | 30 | 0 |
| live by kind x10 pass 0 | 0 | 10 | 0 | 0 | 0 | 0 | 0 | 0 | 43230 | 5990 | 260 | 0 | 0 |
| chain dependencies x10 pass 0 | 10 | 10 | 0 | 0 | 0 | 0 | 0 | 0 | 20460 | 5690 | 109 | 11 | 0 |
| live enroll tokens x10 pass 0 | 0 | 10 | 0 | 0 | 0 | 0 | 0 | 0 | 22690 | 3990 | 190 | 20 | 0 |
| conversations x10 pass 1 | 10 | 10 | 0 | 0 | 0 | 0 | 0 | 0 | 487370 | 0 | 84390 | 0 | 0 |
| live bridge ids x10 pass 1 | 0 | 10 | 0 | 0 | 0 | 0 | 0 | 0 | 88440 | 5990 | 500 | 0 | 0 |
| live by kind x10 pass 1 | 0 | 10 | 0 | 0 | 0 | 0 | 0 | 0 | 43230 | 5990 | 260 | 0 | 0 |
| chain dependencies x10 pass 1 | 10 | 10 | 0 | 0 | 0 | 0 | 0 | 0 | 20460 | 5690 | 120 | 0 | 0 |
| live enroll tokens x10 pass 1 | 0 | 10 | 0 | 0 | 0 | 0 | 0 | 0 | 22690 | 3990 | 210 | 0 | 0 |
| retention no expired rows x10 | 0 | 0 | 0 | 0 | 10 | 0 | 0 | 10 | 70860 | 5990 | 260 | 0 | 0 |
| candidate indexes live bridge ids x10 | 0 | 10 | 0 | 0 | 0 | 0 | 0 | 0 | 82430 | 5990 | 60 | 0 | 0 |
| candidate indexes live server kind x10 | 0 | 10 | 0 | 0 | 0 | 0 | 0 | 0 | 28640 | 0 | 160 | 0 | 0 |
| candidate indexes dependencies x10 | 0 | 10 | 0 | 0 | 0 | 0 | 0 | 0 | 1850 | 0 | 50 | 0 | 0 |
| candidate indexes live tokens x10 | 0 | 10 | 0 | 0 | 0 | 0 | 0 | 0 | 3320 | 0 | 240 | 0 | 0 |
| candidate indexes retention x10 | 0 | 0 | 0 | 0 | 10 | 0 | 0 | 10 | 690 | 0 | 50 | 0 | 0 |
