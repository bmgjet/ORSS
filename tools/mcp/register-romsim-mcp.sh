#!/usr/bin/env bash
# Point Claude Code at this project's MCP server, from Linux or macOS (or Git Bash).
#
# The PowerShell script beside this one does the same job and rather more - it can read the port and
# password out of the app's own settings on Windows, and knows about the head-less server modes.
# This one covers the case that matters across machines: the app is running somewhere with
# Settings > MCP server switched on, and the agent is here.
#
#   ./register-romsim-mcp.sh --host tuning-pc --password 'the-password'
#   ./register-romsim-mcp.sh --host tuning-pc --password 'pw' --env-token
#   ./register-romsim-mcp.sh --host tuning-pc --password 'pw' --test
#   ./register-romsim-mcp.sh --host tuning-pc --password 'pw' --call transfer_dir
#   ./register-romsim-mcp.sh --stdio                       # server on this machine, no window
#
set -euo pipefail

HOST=127.0.0.1
PORT=8765
PASSWORD=""
NAME=okirom
MODE=http
ENV_TOKEN=0
TEST_ONLY=0
FORCE=0
CALL=""
CALL_ARGS='{}'

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CONFIG="$REPO_ROOT/.mcp.json"
ROOT="$REPO_ROOT"

usage() {
    sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

  --host NAME          where the app is (default 127.0.0.1)
  --port N             default 8765
  --password PW        the password from Settings > MCP server
  --env-token          write ${OKIROM_MCP_TOKEN} into .mcp.json instead of the password
  --name NAME          what to call the server in .mcp.json (default okirom)
  --root DIR           workspace folder for --stdio (default: the repository root)
  --config PATH        where to write (default: <repo>/.mcp.json)
  --stdio              register the head-less stdio server on this machine instead
  --call TOOL          call one tool and print the answer, then stop
  --call-args JSON     arguments for --call
  --test               probe and report; write nothing
  --force              replace an existing entry without asking
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --host)       HOST="$2"; shift 2 ;;
        --port)       PORT="$2"; shift 2 ;;
        --password)   PASSWORD="$2"; shift 2 ;;
        --env-token)  ENV_TOKEN=1; shift ;;
        --name)       NAME="$2"; shift 2 ;;
        --root)       ROOT="$2"; shift 2 ;;
        --config)     CONFIG="$2"; shift 2 ;;
        --stdio)      MODE=stdio; shift ;;
        --call)       CALL="$2"; shift 2 ;;
        --call-args)  CALL_ARGS="$2"; shift 2 ;;
        --test)       TEST_ONLY=1; shift ;;
        --force)      FORCE=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done

step() { printf '\033[36m==> %s\033[0m\n' "$1"; }
ok()   { printf '\033[32m    %s\033[0m\n' "$1"; }
warn() { printf '\033[33m    %s\033[0m\n' "$1"; }
bad()  { printf '\033[31m    %s\033[0m\n' "$1"; }
note() { printf '\033[90m    %s\033[0m\n' "$1"; }

command -v curl >/dev/null 2>&1 || { echo "curl is needed and was not found" >&2; exit 2; }

# A working Python, not just something of that name: on Windows "python3" is often the Store stub,
# which exists, answers `command -v` and then refuses to run anything.
PY=""
for candidate in python3 python py; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    if [ "$candidate" = py ]; then
        py -3 -c 'print(1)' >/dev/null 2>&1 && PY="py -3" && break
    elif "$candidate" -c 'print(1)' >/dev/null 2>&1; then
        PY="$candidate"; break
    fi
done
[ -n "$PY" ] || { echo "a working python3 is needed (it does the JSON); none of python3/python/py runs" >&2; exit 2; }

# ---------------------------------------------------------------- one JSON-RPC call
# Prints the `result` as JSON on success; exits non-zero with a readable reason otherwise.
rpc() {
    local method="$1" params="${2:-null}" url="http://$HOST:$PORT/mcp"
    local body status out
    body=$($PY -c '
import json,sys
method, params = sys.argv[1], sys.argv[2]
msg = {"jsonrpc":"2.0","id":1,"method":method}
if params != "null": msg["params"] = json.loads(params)
print(json.dumps(msg))' "$method" "$params")
    local args=(-sS --max-time 20 -o /tmp/romsim-mcp.$$ -w '%{http_code}'
                -H 'Content-Type: application/json' -H 'Accept: application/json'
                --data-binary "$body")
    [ -n "$PASSWORD" ] && args+=(-H "Authorization: Bearer $PASSWORD")
    status=$(curl "${args[@]}" "$url") || { bad "could not reach $url"; rm -f /tmp/romsim-mcp.$$; return 1; }
    out=$(cat /tmp/romsim-mcp.$$); rm -f /tmp/romsim-mcp.$$
    case "$status" in
        200) ;;
        401) bad "the password was wrong or missing (Settings > MCP server)"; return 1 ;;
        429) bad "too many failed logins from here; the server locks an address out for five minutes"; return 1 ;;
        405) bad "that URL wants a POST - check the path ends in /mcp"; return 1 ;;
        *)   bad "HTTP $status: $out"; return 1 ;;
    esac
    $PY -c '
import json,sys
r = json.load(sys.stdin)
if r.get("error"):
    sys.stderr.write("    " + str(r["error"].get("message","error")) + "\n")
    sys.exit(1)
print(json.dumps(r.get("result")))' <<<"$out"
}

# the text of a tools/call answer
call_text() {
    local name="$1" arguments="$2"
    rpc tools/call "$($PY -c '
import json,sys
print(json.dumps({"name": sys.argv[1], "arguments": json.loads(sys.argv[2])}))' "$name" "$arguments")" \
    | $PY -c '
import json,sys
r = json.load(sys.stdin)
print("\n".join(c.get("text","") for c in (r or {}).get("content", [])))'
}

merge_config() {
    local path="$1" name="$2" entry="$3" force="$4"
    [ -f "$path" ] && cp "$path" "$path.bak"
    $PY - "$path" "$name" "$entry" "$force" <<'PYEOF'
import json, os, sys
path, name, entry, force = sys.argv[1], sys.argv[2], json.loads(sys.argv[3]), sys.argv[4] == "1"
cfg = {}
if os.path.exists(path):
    try:
        with open(path) as f: cfg = json.load(f)
    except Exception:
        print("    the existing file is not valid JSON; replacing it (a copy is kept as .bak)")
        cfg = {}
cfg.setdefault("mcpServers", {})
if name in cfg["mcpServers"] and not force:
    print(f"    '{name}' is already there; run again with --force to replace it")
    sys.exit(3)
cfg["mcpServers"][name] = entry
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
print(f"    wrote {path}")
PYEOF
}

printf '\n'
step "Rom Sim Studio MCP -> Claude Code  ($MODE)"

if [ "$MODE" = stdio ]; then
    EXE=""
    for cfg in Release Debug; do
        p="$REPO_ROOT/src/OkiRomSim.Desktop/bin/$cfg/net10.0/RomSimStudio"
        [ -f "$p" ] && EXE="$p" && break
    done
    [ -n "$EXE" ] || { bad "RomSimStudio was not built. Run: dotnet build OkiRomSim.sln -c Release"; exit 1; }
    ok "server: $EXE --mcp --root $ROOT"
    warn "stdio has no window behind it: app_open, rom_upload, simulator and datalog will refuse."
    [ "$TEST_ONLY" = 1 ] && { printf '\n'; exit 0; }
    entry=$($PY -c '
import json,sys
print(json.dumps({"command": sys.argv[1], "args": ["--mcp", "--root", sys.argv[2]]}))' "$EXE" "$ROOT")
    merge_config "$CONFIG" "$NAME" "$entry" "$FORCE"
    printf '\n'
    exit 0
fi

step "checking http://$HOST:$PORT/mcp"
[ -n "$PASSWORD" ] || warn "no password. If the server has one set, every call comes back 401."

if ! curl -sS --max-time 10 "http://$HOST:$PORT/" | grep -q romsim-mcp; then
    bad "nothing that looks like the Rom Sim Studio server answered http://$HOST:$PORT/"
    note "The app has to be running with Settings > MCP server switched on. On another machine, tick"
    note "'Allow remote connections' there (which needs a password of 8+ characters) and let the port"
    note "through that machine's firewall."
    exit 1
fi

init=$(rpc initialize '{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"register-romsim-mcp.sh","version":"1"}}') || exit 1
ok "$($PY -c '
import json,sys
r = json.load(sys.stdin)
i = r.get("serverInfo", {})
print(i.get("name"), i.get("version"), "- protocol", r.get("protocolVersion"))' <<<"$init")"

tools=$(rpc tools/list 'null') || exit 1
ok "$($PY -c 'import json,sys; print(len(json.load(sys.stdin).get("tools",[])), "tools")' <<<"$tools")"

# every server lists app_open; only the one inside the window can run it, and session_info says which
if info=$(call_text session_info '{}'); then
    if grep -qi 'no app session' <<<"$info"; then
        warn "a head-less server: no window behind it."
        warn "app_open, rom_upload/rom_download, simulator and datalog are listed but will refuse;"
        warn "the file, disassembly, assembly and calibration tools all work (pass \`path\` to each)."
    else
        ok "the server inside the app: it works on the ROM open in the window"
        while IFS= read -r line; do [ -n "$line" ] && note "$line"; done <<<"$info"
    fi
fi
transfer=$(call_text transfer_dir '{}' || true)
[ -n "$transfer" ] && ok "$(head -n1 <<<"$transfer")"

if [ -n "$CALL" ]; then
    step "calling $CALL"
    printf '\n'
    call_text "$CALL" "$CALL_ARGS"
    printf '\n'
    exit 0
fi
if [ "$TEST_ONLY" = 1 ]; then printf '\n'; ok "the link is good; nothing was written (--test)"; printf '\n'; exit 0; fi

TOKEN="$PASSWORD"
if [ "$ENV_TOKEN" = 1 ] && [ -n "$PASSWORD" ]; then
    TOKEN='${OKIROM_MCP_TOKEN}'
    ok "the config will refer to OKIROM_MCP_TOKEN rather than hold the password"
    note "Set it where your shell will find it:  export OKIROM_MCP_TOKEN='<password>'"
fi
entry=$($PY -c '
import json,sys
e = {"type": "http", "url": sys.argv[1]}
if sys.argv[2]: e["headers"] = {"Authorization": "Bearer " + sys.argv[2]}
print(json.dumps(e))' "http://$HOST:$PORT/mcp" "$TOKEN")
merge_config "$CONFIG" "$NAME" "$entry" "$FORCE"
if [ "$ENV_TOKEN" != 1 ] && [ -n "$PASSWORD" ]; then
    warn "$CONFIG now holds the password in clear. Keep it out of anything you share, or use --env-token."
fi

printf '\n'
step "Claude Code"
if command -v claude >/dev/null 2>&1; then
    ok "found $(command -v claude)"
    note ".mcp.json is picked up when Claude Code opens this folder, so nothing else is needed."
    note "To add it for every folder instead:"
    note "  claude mcp add --transport http $NAME \"http://$HOST:$PORT/mcp\" --header \"Authorization: Bearer <password>\""
    note "Check with:  claude mcp list"
else
    note "The 'claude' CLI is not on the PATH (the desktop app carries its own copy)."
    note "Nothing to do: .mcp.json is read by whichever Claude Code opens this folder."
fi

printf '\n'
step "In a session, ask the agent to"
note "  - call \"help\" on the $NAME server first; it lists every tool and the order to use them in"
note "  - across machines: transfer_dir, then file_upload in chunks, then app_open"
note "  - then cal_detect, cal_read/cal_write, simulator, datalog, emulator on the ROM that is open"
printf '\n'
