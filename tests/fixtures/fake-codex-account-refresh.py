#!/usr/bin/python3
"""Reorder synthetic account snapshots; never invokes Codex or reads credentials."""
import json
import os
import sys
import threading

mode = os.environ["SCRIV_FAKE_ACCOUNT_MODE"]
reads = 0
lock = threading.Lock()

def send(message):
    with lock:
        print(json.dumps(message), flush=True)

signed = {"account": {"type": "chatgpt", "email": "current@example.invalid"}, "requiresOpenaiAuth": True}
signed_out = {"account": None, "requiresOpenaiAuth": True}
for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    if "id" not in message:
        continue
    if method == "initialize": result = {"userAgent": "synthetic-test"}
    elif method == "account/read":
        reads += 1
        if reads == 2:
            send({"method": "account/updated", "params": {}})
            old = signed if mode == "stale_signed_in" else signed_out
            delayed = {"id": message["id"], "error": {"code": -1, "message": "stale account error"}} if mode == "stale_failure" else {"id": message["id"], "result": old}
            threading.Timer(0.35, send, args=[delayed]).start()
            continue
        if reads >= 3 and mode == "latest_failure":
            send({"id": message["id"], "error": {"code": -1, "message": "current account error"}})
            continue
        result = signed_out if reads >= 3 and mode == "stale_signed_in" else signed
    elif method == "model/list":
        send({"id": message["id"], "result": {"data": [{"model": "synthetic", "isDefault": True}], "nextCursor": None}})
        send({"method": "account/updated", "params": {}})
        continue
    else: result = {}
    send({"id": message["id"], "result": result})
