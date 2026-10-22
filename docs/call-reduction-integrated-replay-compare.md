runs per side: 15 (fresh fixture each run); b = baseline d4225b3a, i = integrated head
| Scenario | HTTP modeled | SELECT | INSERT | UPDATE | DELETE | Writes (DML) | VM steps | Fullscan | Cache page writes | p50 µs | p95 µs | p99 µs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| vault identical touch x30 dedicated conn | 30 | 0 | 0 | 30 | 0 | 30 | **1560→1170** | 0 | 0 | 429→572 | 447→589 | 452→590 |
| shell identical registration x92 | 92 | 0 | 92 | 0 | 0 | 92 | **13708→13248** | 0 | **92→0** | 10648→14744 | 10714→15395 | 10721→15570 |
| bridge identical save x120 | 0 | 0 | 120 | 0 | 0 | 120 | 14040 | 0 | 0 | 4395→4403 | 5150→4502 | 5877→4525 |
| bridge heartbeat same state x120 service | 0 | 120 | 120 | 0 | 0 | 120 | 18480 | 0 | 0 | 8667→8612 | 9651→9416 | 9859→9986 |
| bridge offline repeated x3 service | 0 | 3 | 1 | 0 | 0 | 1 | 228 | 0 | 1 | 173→172 | 196→196 | 217→215 |
| bridge vault status same x120 service | 0 | 120 | 1 | 0 | 0 | 1 | 4557 | 0 | 1 | 3603→3577 | 4238→3756 | 5088→3805 |
| conversation read x21 service | 21 | 42 | 21 | 1 | 0 | 22 | **27071→25578** | 0 | **104→34** | 4485→3131 | 5021→3220 | 5302→3221 |
| conversation already read x20 service | 20 | 40 | 20 | 0 | 0 | 20 | **17380→17100** | 0 | **80→20** | 3278→2264 | 3403→2379 | 3465→2429 |
| conversation already read changing clock x20 | 20 | 40 | 20 | 0 | 0 | 20 | **17380→17100** | 0 | **100→40** | 3436→2514 | 3661→2576 | 3723→2601 |
| mark read same 10 ids x21 service | 21 | 0 | 0 | 21 | 0 | 21 | **17522→3423** | 0 | **133→5** | 3345→1470 | 3828→1523 | 4108→1536 |
| agent already read same 10 ids x20 service | 20 | 0 | 0 | 20 | 0 | 20 | **16640→2660** | 0 | **141→0** | 3193→1290 | 3562→1367 | 3879→1432 |
| task comments x30 service engine no projector | 30 | 30 | 60 | 0 | 0 | 60 | 4710 | 0 | 300 | 6505→6539 | 6936→6697 | 7566→6702 |
| auth user lookup component x10 | 10 | 10 | 0 | 0 | 0 | 0 | 190 | 0 | 0 | 117→117 | 129→141 | 131→161 |
| shell owner list component x10 | 10 | 10 | 0 | 0 | 0 | 0 | 202660 | 0 | 0 | 11341→11342 | 11784→12156 | 12086→12666 |
| card detail component x10 | 10 | 10 | 0 | 0 | 0 | 0 | 340 | 0 | 0 | 240→246 | 285→334 | 313→410 |
| task detail component x10 | 10 | 10 | 0 | 0 | 0 | 0 | 370 | 0 | 0 | 258→263 | 274→334 | 279→445 |
| agent identity component x10 | 10 | 10 | 0 | 0 | 0 | 0 | 210 | 0 | 0 | 130→136 | 140→198 | 145→250 |
| chain list component x10 | 10 | 10 | 0 | 0 | 0 | 0 | 14540 | 0 | 0 | 1396→1359 | 1499→1467 | 1561→1485 |
| empty search delta enrichment helper x10 | 10 | **20→0** | 0 | 0 | 0 | 0 | **642440→0** | 0 | 0 | 32312→3 | 33059→3 | 33133→3 |
| conversations x10 pass 0 | 10 | 10 | 0 | 0 | 0 | 0 | 487370 | 0 | 0 | 27497→26971 | 28147→28431 | 28225→28920 |
| live bridge ids x10 pass 0 | 0 | 10 | 0 | 0 | 0 | 0 | 88440 | 5990 | 0 | 2916→2916 | 3101→3056 | 3216→3194 |
| live by kind x10 pass 0 | 0 | 10 | 0 | 0 | 0 | 0 | **43230→28640** | **5990→0** | 0 | 2076→1943 | 2160→2026 | 2176→2027 |
| chain dependencies x10 pass 0 | 10 | 10 | 0 | 0 | 0 | 0 | **20460→1850** | **5690→0** | 0 | 892→458 | 947→511 | 952→577 |
| live enroll tokens x10 pass 0 | 0 | 10 | 0 | 0 | 0 | 0 | 22690 | 3990 | 0 | 1191→1198 | 1226→1260 | 1228→1278 |
| conversations x10 pass 1 | 10 | 10 | 0 | 0 | 0 | 0 | 487370 | 0 | 0 | 27093→26339 | 27811→27800 | 28028→27810 |
| live bridge ids x10 pass 1 | 0 | 10 | 0 | 0 | 0 | 0 | 88440 | 5990 | 0 | 2851→2887 | 2930→3048 | 2941→3053 |
| live by kind x10 pass 1 | 0 | 10 | 0 | 0 | 0 | 0 | **43230→28640** | **5990→0** | 0 | 2078→1955 | 2132→2090 | 2148→2155 |
| chain dependencies x10 pass 1 | 10 | 10 | 0 | 0 | 0 | 0 | **20460→1850** | **5690→0** | 0 | 864→429 | 946→459 | 977→459 |
| live enroll tokens x10 pass 1 | 0 | 10 | 0 | 0 | 0 | 0 | 22690 | 3990 | 0 | 1145→1161 | 1230→1228 | 1277→1233 |
| retention no expired rows x10 | 0 | 0 | 0 | 0 | 10 | 10 | **70860→680** | **5990→0** | 0 | 2269→313 | 2500→326 | 2513→331 |
| candidate indexes live bridge ids x10 | 0 | 10 | 0 | 0 | 0 | 0 | 82430 | 5990 | 0 | 2448→2408 | 2696→2610 | 2901→2727 |
| candidate indexes live server kind x10 | 0 | 10 | 0 | 0 | 0 | 0 | 28640 | 0 | 0 | 1707→1912 | 1771→2219 | 1804→2537 |
| candidate indexes dependencies x10 | 0 | 10 | 0 | 0 | 0 | 0 | 1850 | 0 | 0 | 411→441 | 473→472 | 543→480 |
| candidate indexes live tokens x10 | 0 | 10 | 0 | 0 | 0 | 0 | 3320 | 0 | 0 | 687→702 | 877→785 | 1126→896 |
| candidate indexes retention x10 | 0 | 0 | 0 | 0 | 10 | 10 | **690→730** | 0 | 0 | 299→317 | 329→394 | 341→403 |
| vault advancing 4s x30 dedicated conn | 30 | 0 | 0 | 30 | 0 | 30 | **1562→1172** | 0 | **30→0** | 45274→2916 | 48323→2987 | 48447→2988 |
| bridge heartbeat advancing 45s x120 service | 0 | 120 | 120 | 0 | 0 | 120 | 18480 | 0 | 120 | 13087→13013 | 13758→13814 | 13871→14005 |
| conversation project links x10 | (integrated only) |
