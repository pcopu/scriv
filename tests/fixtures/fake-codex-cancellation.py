#!/usr/bin/python3
"""Local JSON-RPC fixture: no credentials, Codex executable, or model calls."""
import json
import os
import sys
import time

mode = os.environ["SCRIV_FAKE_MODE"]

def send(message):
    print(json.dumps(message), flush=True)

for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    if method is None and message.get("id") == "input-request":
        if mode in ("unrelated", "missing"):
            send({"method": "turn/completed", "params": {"threadId": "scriv-thread", "turn": {
                "id": "scriv-turn", "status": "failed", "error": {"message": "Synthetic turn finished"}
            }}})
        continue
    if "id" not in message:
        continue
    if method == "initialize": result = {"userAgent": "synthetic-test"}
    elif method == "account/read": result = {"account": {"type": "chatgpt", "email": "fake@example.invalid"}, "requiresOpenaiAuth": True}
    elif method == "model/list": result = {"data": [{"model": "synthetic", "isDefault": True}], "nextCursor": None}
    elif method == "thread/start": result = {"thread": {"id": "scriv-thread"}}
    elif method == "turn/start":
        if mode == "late": time.sleep(0.4)
        send({"id": message["id"], "result": {"turn": {"id": "scriv-turn"}}})
        if mode in ("unrelated", "missing", "own"):
            params = {"turnId": "scriv-turn", "questions": []}
            if mode != "missing": params["threadId"] = "another-thread" if mode == "unrelated" else "scriv-thread"
            send({"id": "input-request", "method": "item/tool/requestUserInput", "params": params})
        continue
    elif method == "turn/interrupt":
        with open(os.environ["SCRIV_FAKE_INTERRUPT_LOG"], "a", encoding="utf-8") as log:
            log.write(json.dumps(message["params"]) + "\n")
        if mode == "acknowledged": send({"id": message["id"], "result": {}})
        else: send({"id": message["id"], "error": {"code": -1, "message": "Synthetic interrupt failure"}})
        continue
    elif method == "thread/read": result = {"thread": {"id": "scriv-thread", "turns": [{"id": "scriv-turn", "status": "interrupted", "items": []}]}}
    else: result = {}
    send({"id": message["id"], "result": result})
