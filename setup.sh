#!/usr/bin/env bash
# setup.sh — ติดตั้ง/รัน workshop นี้ให้จบในคำสั่งเดียว
#
#   ./setup.sh                 โหมดถาม-ตอบ (แนะนำสำหรับผู้เข้า workshop)
#   ./setup.sh --mcp-only      รันเฉพาะ MCP server (ไม่ต้องมี key ของ OpenAI)
#   ./setup.sh --full          รันสแตกเต็ม (ต้องมี tunnel id + runtime API key)
#   ./setup.sh --status        ดูสถานะ + ยิง smoke test
#   ./setup.sh --down          ปิดทุกอย่าง
#
# ตัวเลือกเสริม: --auth / --no-auth   --port <n>   --yes   --help

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; BOLD=$'\033[1m'; OFF=$'\033[0m'
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✓%s %s\n' "$GREEN" "$OFF" "$*"; }
warn() { printf '%s!%s %s\n' "$YELLOW" "$OFF" "$*"; }
die()  { printf '%s✗%s %s\n' "$RED" "$OFF" "$*" >&2; exit 1; }
head1(){ printf '\n%s%s%s\n' "$BOLD" "$*" "$OFF"; }

MODE=""            # mcp | full
AUTH=""            # yes | no
PORT=""
ASSUME_YES=0
ACTION="up"

while [ $# -gt 0 ]; do
  case "$1" in
    --mcp-only) MODE="mcp" ;;
    --full)     MODE="full" ;;
    --auth)     AUTH="yes" ;;
    --no-auth)  AUTH="no" ;;
    --port)     PORT="${2:-}"; shift ;;
    --yes|-y)   ASSUME_YES=1 ;;
    --status)   ACTION="status" ;;
    --down)     ACTION="down" ;;
    --help|-h)  awk 'NR>1 && /^#/{sub(/^# ?/,"");print;next} NR>1{exit}' "$0"; exit 0 ;;
    *)          die "ไม่รู้จักตัวเลือก: $1 (ดู --help)" ;;
  esac
  shift
done

# ── env helpers ────────────────────────────────────────────────────────────
env_get() { [ -f .env ] && sed -n "s/^$1=//p" .env | head -1 || true; }
env_set() {
  local key="$1" val="$2" tmp
  tmp="$(mktemp)"
  if grep -q "^${key}=" .env 2>/dev/null; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in "${key}="*) printf '%s=%s\n' "$key" "$val" ;; *) printf '%s\n' "$line" ;; esac
    done < .env > "$tmp"
  else
    { cat .env 2>/dev/null; printf '%s=%s\n' "$key" "$val"; } > "$tmp"
  fi
  mv "$tmp" .env
  chmod 600 .env
}

compose_files() {
  if [ "$(env_get MODE_FILE)" = "mcp" ]; then echo "-f docker-compose.mcp.yml"; else echo ""; fi
}

mcp_url() { echo "http://127.0.0.1:$(env_get MCP_HOST_PORT || echo 8090)"; }

smoke() {
  local base token hdr code
  base="$(mcp_url)"; token="$(env_get MCP_AUTH_TOKEN)"
  hdr=(); [ -n "$token" ] && hdr=(-H "Authorization: Bearer $token")
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "$base/healthz" || true)
  [ "$code" = "200" ] || { warn "/healthz ตอบ $code"; return 1; }
  ok "healthz 200"
  local body
  body=$(curl -s -m 8 "${hdr[@]}" \
      -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
      -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' "$base/mcp" || true)
  if printf '%s' "$body" | grep -q '"name":"ping"'; then
    ok "tools/list ตอบกลับ: $(printf '%s' "$body" | grep -o '"name":"[a-z_]*"' | wc -l | tr -d ' ') tools"
  else
    warn "tools/list ไม่ผ่าน — ลองดู: docker compose logs mcp-server"; return 1
  fi
  if [ -n "$token" ]; then
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 8 \
        -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
        -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' "$base/mcp" || true)
    [ "$code" = "401" ] && ok "ไม่มี token โดนปฏิเสธ (401)" || warn "คาดว่าจะได้ 401 แต่ได้ $code"
  fi
}

# ── --down / --status ──────────────────────────────────────────────────────
if [ "$ACTION" = "down" ]; then
  head1 "ปิดทุกสแตก"
  docker compose --profile stub --profile cf-quick --profile cf-named down --remove-orphans 2>/dev/null || true
  docker compose -f docker-compose.mcp.yml down --remove-orphans 2>/dev/null || true
  ok "ปิดเรียบร้อย (ไฟล์ใน workspace/ และ .env ยังอยู่)"
  exit 0
fi

if [ "$ACTION" = "status" ]; then
  head1 "สถานะ container"
  docker compose ps 2>/dev/null || true
  docker compose -f docker-compose.mcp.yml ps 2>/dev/null || true
  head1 "smoke test — $(mcp_url)"
  smoke || true
  if docker ps --format '{{.Names}}' | grep -q '^openai-tunnel-client$'; then
    head1 "tunnel-client"
    printf 'healthz: %s   readyz: %s\n' \
      "$(curl -s -m 5 "http://127.0.0.1:$(env_get TUNNEL_HEALTH_PORT || echo 8091)/healthz" || echo '-')" \
      "$(curl -s -m 5 "http://127.0.0.1:$(env_get TUNNEL_HEALTH_PORT || echo 8091)/readyz" || echo '-')"
    curl -s -m 5 "http://127.0.0.1:$(env_get TUNNEL_HEALTH_PORT || echo 8091)/metrics" 2>/dev/null \
      | grep '^commands_poll_cycles_total' | head -1 || true
  fi
  exit 0
fi

# ── 1. ตรวจเครื่องมือ ──────────────────────────────────────────────────────
head1 "1/5 ตรวจเครื่องมือที่ต้องใช้"
command -v docker >/dev/null || die "ไม่พบ docker — ติดตั้งก่อนที่ https://docs.docker.com/get-docker/"
docker compose version >/dev/null 2>&1 || die "ไม่พบ docker compose v2 (ลอง: docker compose version)"
docker info >/dev/null 2>&1 || die "docker daemon ไม่ทำงาน หรือ user นี้ไม่มีสิทธิ์ (ลอง: sudo usermod -aG docker \$USER)"
command -v curl >/dev/null || die "ไม่พบ curl"
ok "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null)  /  compose $(docker compose version --short 2>/dev/null)"

# ── 2. .env ────────────────────────────────────────────────────────────────
head1 "2/5 เตรียมไฟล์ .env"
if [ ! -f .env ]; then
  cp .env.example .env; chmod 600 .env; ok "สร้าง .env จาก .env.example"
else
  ok ".env มีอยู่แล้ว (ไม่ทับของเดิม)"
fi
env_set PUID "$(id -u)"
env_set PGID "$(id -g)"

# พอร์ตว่างไหม
port_busy() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && { exec 3<&- 3>&-; return 0; } || return 1; }
if [ -z "$PORT" ]; then PORT="$(env_get MCP_HOST_PORT)"; PORT="${PORT:-8090}"; fi
if port_busy "$PORT" && ! docker ps --format '{{.Ports}}' | grep -q ":$PORT->"; then
  for p in $(seq $((PORT+1)) $((PORT+20))); do
    port_busy "$p" || { warn "พอร์ต $PORT ไม่ว่าง → ใช้ $p แทน"; PORT="$p"; break; }
  done
fi
env_set MCP_HOST_PORT "$PORT"
ok "MCP server จะใช้ 127.0.0.1:$PORT"

# ── 3. เลือกโหมด ───────────────────────────────────────────────────────────
head1 "3/5 เลือกโหมด"
if [ -z "$MODE" ]; then
  if [ "$ASSUME_YES" = "1" ] || [ ! -t 0 ]; then
    MODE="mcp"
  else
    say "  ${BOLD}1${OFF}) MCP server อย่างเดียว — ใช้กับ Claude Code / Gemini CLI / Cursor (ไม่ต้องมี key)"
    say "  ${BOLD}2${OFF}) สแตกเต็ม + ท่อ OpenAI — ให้ ChatGPT เข้ามาถึง (ต้องมี tunnel id + API key)"
    printf 'เลือก [1/2] (ดีฟอลต์ 1): '
    read -r choice || choice=1
    case "${choice:-1}" in 2) MODE="full" ;; *) MODE="mcp" ;; esac
  fi
fi
env_set MODE_FILE "$MODE"
ok "โหมด: $MODE"

if [ "$MODE" = "full" ]; then
  tid="$(env_get CONTROL_PLANE_TUNNEL_ID)"; key="$(env_get CONTROL_PLANE_API_KEY)"
  if [ -z "$tid" ] || [ "$tid" = "tunnel_0123456789abcdef0123456789abcdef" ]; then
    if [ -t 0 ] && [ "$ASSUME_YES" != "1" ]; then
      say "  tunnel id เอาจาก https://platform.openai.com/settings/organization/tunnels"
      printf '  CONTROL_PLANE_TUNNEL_ID: '; read -r tid; env_set CONTROL_PLANE_TUNNEL_ID "$tid"
    else
      die "ยังไม่ได้ตั้ง CONTROL_PLANE_TUNNEL_ID ใน .env"
    fi
  fi
  if [ -z "$key" ] || [ "$key" = "sk-..." ]; then
    if [ -t 0 ] && [ "$ASSUME_YES" != "1" ]; then
      say "  runtime API key (ไม่ใช่ admin key) จาก https://platform.openai.com/settings/organization/api-keys"
      printf '  CONTROL_PLANE_API_KEY: '; read -rs key; echo; env_set CONTROL_PLANE_API_KEY "$key"
    else
      die "ยังไม่ได้ตั้ง CONTROL_PLANE_API_KEY ใน .env"
    fi
  fi
  ok "credential ของ tunnel พร้อม"
fi

# ── 4. auth token ──────────────────────────────────────────────────────────
head1 "4/5 auth ของ MCP server"
cur_token="$(env_get MCP_AUTH_TOKEN)"
if [ -z "$AUTH" ]; then
  if [ -n "$cur_token" ]; then AUTH="yes"
  elif [ "$ASSUME_YES" = "1" ] || [ ! -t 0 ]; then AUTH="no"
  else
    printf 'เปิด bearer token auth ไหม? (แนะนำ ถ้าจะเปิดออกนอกเครื่อง) [y/N]: '
    read -r a || a=n
    case "$a" in y|Y|yes) AUTH="yes" ;; *) AUTH="no" ;; esac
  fi
fi
if [ "$AUTH" = "yes" ]; then
  if [ -z "$cur_token" ]; then
    if command -v openssl >/dev/null; then cur_token="$(openssl rand -hex 32)"
    else cur_token="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"; fi
    env_set MCP_AUTH_TOKEN "$cur_token"
    ok "สร้าง token ใหม่แล้ว (เก็บใน .env)"
  else
    ok "ใช้ token เดิมใน .env"
  fi
else
  env_set MCP_AUTH_TOKEN ""
  warn "ปิด auth — ใช้ได้เฉพาะตอน bind 127.0.0.1 เท่านั้น อย่าเปิด public tunnel"
fi

# ── 5. build + up ──────────────────────────────────────────────────────────
head1 "5/5 build และ start"
# shellcheck disable=SC2046
docker compose $(compose_files) up -d --build

printf 'รอ mcp-server พร้อม'
for _ in $(seq 1 30); do
  if curl -s -o /dev/null -m 2 "$(mcp_url)/healthz"; then echo; break; fi
  printf '.'; sleep 2
done
echo

head1 "smoke test"
smoke || warn "smoke test ไม่ผ่านทั้งหมด — ดู log ด้วย: docker compose $(compose_files) logs"

# ── สรุป ───────────────────────────────────────────────────────────────────
TOKEN="$(env_get MCP_AUTH_TOKEN)"
head1 "พร้อมใช้งานแล้ว 🎉"
say "MCP endpoint : ${BLUE}$(mcp_url)/mcp${OFF}"
[ -n "$TOKEN" ] && say "Bearer token : $TOKEN"
say ""
say "${BOLD}ต่อกับ agent ในเครื่อง${OFF}"
if [ -n "$TOKEN" ]; then
  say "  claude mcp add --transport http workspace $(mcp_url)/mcp --header \"Authorization: Bearer $TOKEN\""
else
  say "  claude mcp add --transport http workspace $(mcp_url)/mcp"
fi
say "  Gemini CLI → ~/.gemini/settings.json:"
if [ -n "$TOKEN" ]; then
  say "    { \"mcpServers\": { \"workspace\": { \"httpUrl\": \"$(mcp_url)/mcp\","
  say "        \"headers\": { \"Authorization\": \"Bearer $TOKEN\" } } } }"
else
  say "    { \"mcpServers\": { \"workspace\": { \"httpUrl\": \"$(mcp_url)/mcp\" } } }"
fi

if [ "$MODE" = "full" ]; then
  say ""
  say "${BOLD}ท่อ OpenAI${OFF}"
  say "  log      : docker compose logs -f tunnel-client   (รอบรรทัด 🟢 tunnel-client started)"
  say "  health   : http://127.0.0.1:$(env_get TUNNEL_HEALTH_PORT || echo 8091)/ui"
  say "  connector: https://chatgpt.com/#settings/Connectors  (เพิ่มตอน daemon กำลังรัน)"
fi
say ""
say "${BOLD}คำสั่งที่ใช้บ่อย${OFF}"
say "  ./setup.sh --status     ดูสถานะ + smoke test"
say "  ./setup.sh --down       ปิดทุกอย่าง"
say "  บทเรียนทีละขั้น: WORKSHOP.md"
