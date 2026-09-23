import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

API_KEY = os.getenv("MOCK_UPSTREAM_API_KEY", "mock-upstream-key")
PORT = int(os.getenv("MOCK_UPSTREAM_PORT", "8080"))
TIMEOUT_SECONDS = float(os.getenv("MOCK_TIMEOUT_SECONDS", "5"))
COUNTERS = {}
COUNTERS_LOCK = threading.Lock()


def send_json(handler, status, payload):
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


def increment_counter(name):
    with COUNTERS_LOCK:
        COUNTERS[name] = COUNTERS.get(name, 0) + 1
        return COUNTERS[name]


class Handler(BaseHTTPRequestHandler):
    server_version = "relay-mock-upstream/1.0"

    def log_message(self, format, *args):
        print("%s - %s" % (self.address_string(), format % args), flush=True)

    def authorized(self):
        return self.headers.get("Authorization", "") == f"Bearer {API_KEY}"

    def forced_status(self):
        value = self.headers.get("X-Mock-Status", "").strip()
        if value in {"429", "500", "504"}:
            return int(value)
        return None

    def do_GET(self):
        if self.path == "/healthz":
            send_json(self, 200, {"status": "ok"})
            return
        if self.path == "/debug/counters":
            with COUNTERS_LOCK:
                send_json(self, 200, {"counters": dict(COUNTERS)})
            return
        if self.path == "/v1/models":
            if not self.authorized():
                send_json(self, 401, {"error": {"message": "invalid mock upstream key", "type": "authentication_error"}})
                return
            send_json(self, 200, {"object": "list", "data": [
                {"id": "mock-chat", "object": "model", "created": 0, "owned_by": "relay-test"},
                {"id": "mock-stream", "object": "model", "created": 0, "owned_by": "relay-test"},
                {"id": "mock-error-429", "object": "model", "created": 0, "owned_by": "relay-test"},
                {"id": "mock-error-500", "object": "model", "created": 0, "owned_by": "relay-test"},
                {"id": "mock-retry-once", "object": "model", "created": 0, "owned_by": "relay-test"},
                {"id": "mock-retry-always", "object": "model", "created": 0, "owned_by": "relay-test"},
                {"id": "mock-timeout", "object": "model", "created": 0, "owned_by": "relay-test"},
            ]})
            return
        send_json(self, 404, {"error": {"message": "not found"}})

    def do_POST(self):
        if self.path == "/debug/reset":
            with COUNTERS_LOCK:
                COUNTERS.clear()
            send_json(self, 200, {"status": "reset"})
            return
        if not self.authorized():
            send_json(self, 401, {"error": {"message": "invalid mock upstream key", "type": "authentication_error"}})
            return
        length = int(self.headers.get("Content-Length", "0"))
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            send_json(self, 400, {"error": {"message": "invalid json"}})
            return
        model = payload.get("model", "mock-chat")
        forced_status = self.forced_status()
        if forced_status is not None:
            messages = {429: "mock rate limit", 500: "mock upstream failure", 504: "mock upstream timeout"}
            error_types = {429: "rate_limit_error", 500: "server_error", 504: "timeout_error"}
            send_json(self, forced_status, {"error": {"message": messages[forced_status], "type": error_types[forced_status]}})
            return
        if model == "mock-error-429":
            send_json(self, 429, {"error": {"message": "mock rate limit", "type": "rate_limit_error"}})
            return
        if model == "mock-error-500":
            send_json(self, 500, {"error": {"message": "mock upstream failure", "type": "server_error"}})
            return
        if model == "mock-retry-once":
            attempt = increment_counter(model)
            if attempt == 1:
                send_json(self, 500, {"error": {"message": "mock transient failure", "type": "server_error"}})
                return
        if model == "mock-retry-always":
            increment_counter(model)
            send_json(self, 500, {"error": {"message": "mock persistent failure", "type": "server_error"}})
            return
        if model == "mock-timeout":
            time.sleep(TIMEOUT_SECONDS)
        if self.path == "/v1/chat/completions":
            self.chat_completion(payload, model)
            return
        if self.path == "/v1/responses":
            send_json(self, 200, {"id": "resp_mock_1", "object": "response", "model": model, "status": "completed", "output": [{"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "Mock response from relay upstream."}]}], "usage": {"input_tokens": 8, "output_tokens": 7, "total_tokens": 15}})
            return
        send_json(self, 404, {"error": {"message": "not found"}})

    def chat_completion(self, payload, model):
        content = "Mock response from relay upstream."
        if payload.get("messages"):
            last = payload["messages"][-1]
            if isinstance(last, dict) and isinstance(last.get("content"), str):
                content = "Mock echo: " + last["content"]
        if payload.get("stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "keep-alive")
            self.end_headers()
            chunks = [content[:12], content[12:]]
            for index, chunk in enumerate(chunks):
                event = {"id": "chatcmpl_mock_1", "object": "chat.completion.chunk", "created": int(time.time()), "model": model, "choices": [{"index": 0, "delta": {"role": "assistant"} if index == 0 else {"content": chunk}, "finish_reason": None}]}
                self.wfile.write(("data: " + json.dumps(event) + "\n\n").encode("utf-8"))
                self.wfile.flush()
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
            return
        send_json(self, 200, {"id": "chatcmpl_mock_1", "object": "chat.completion", "created": int(time.time()), "model": model, "choices": [{"index": 0, "message": {"role": "assistant", "content": content}, "finish_reason": "stop"}], "usage": {"prompt_tokens": 8, "completion_tokens": 7, "total_tokens": 15}})


if __name__ == "__main__":
    print(f"mock upstream listening on :{PORT}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
