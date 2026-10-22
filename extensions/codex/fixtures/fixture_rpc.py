"""Control the opt-in loopback bridge reducer test with public synthetic tokens."""
import argparse
import json
from pathlib import Path
import socket

def call(token, method, params):
    with socket.create_connection(("127.0.0.1", 45377), timeout=8) as s:
        s.sendall((json.dumps({"v":1,"id":"fixture","token":token,"method":method,"params":params})+"\n").encode())
        data=b""
        while b"\n" not in data:
            part=s.recv(65536)
            if not part:
                break
            data+=part
        return json.loads(data)

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument("action",choices=("inspect","allow","deny","finish"))
    ap.add_argument("token",choices=("fixture-one","fixture-two"))
    ap.add_argument("--save",type=Path)
    args=ap.parse_args()
    report=call(args.token,"fixture.inspect",{})
    if args.save:
        args.save.write_text(json.dumps(report,indent=2)+"\n")
    data=report.get("data",{})
    blockers=data.get("blockers",[])
    print(json.dumps({"extension":data.get("extension"),"events":len(data.get("events",[])),
                      "blockers":blockers}))
    if args.action in ("allow","deny"):
        for blocker in blockers:
            bid=blocker.get("blocker_id")
            print(call(args.token,"fixture.decide",{"blocker_id":bid,"decision":args.action}))
    if args.action=="finish":
        print(call(args.token,"fixture.finish",{}))
        with socket.create_connection(("127.0.0.1",45377),timeout=3):
            pass

if __name__=="__main__":
    main()
