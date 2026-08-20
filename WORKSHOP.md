# Workshop — เอา MCP server ในเครื่องต่อกับ AI บนคลาวด์

> เป้าหมาย: จบ workshop แล้วผู้เข้าร่วมต่อ MCP server ของตัวเองเข้ากับ ChatGPT ได้
> โดยไม่เปิด inbound port สักพอร์ต และเข้าใจว่า MCP server หนึ่งตัวใช้ได้กับ AI ทุกค่าย

| | |
| --- | --- |
| ระยะเวลา | ~90 นาที (Lab 1–4 คือแกนหลัก ~50 นาที) |
| ระดับ | รู้จัก Docker + command line พื้นฐาน |
| ต้องมี | Docker + Docker Compose, บัญชี OpenAI org ที่มีสิทธิ์ Tunnels Read+Use |
| ไม่ต้องมี | public IP, domain, การเปิด firewall |

## สิ่งที่จะได้เรียน

1. MCP server หน้าตาเป็นยังไง คุยกันด้วยอะไร (JSON-RPC over HTTP)
2. ทำไม AI บนคลาวด์ถึงเรียก `localhost` ของเราไม่ได้ และ tunnel แก้ปัญหานี้ยังไง
3. เขียน tool ของตัวเองแล้วให้ ChatGPT เรียกใช้
4. ใส่ auth ก่อนเปิดออกสาธารณะ
5. เทียบท่อของ OpenAI กับ Cloudflare Tunnel

---

## แผนภาพรวม

```
                            ┌──────────────── เครื่องของคุณ ────────────────┐
  ChatGPT / Codex  ────►    │  tunnel-client  ──►  mcp-server  ──►  ./workspace │
  (คลาวด์ OpenAI)  ◄════════│  (outbound only)                                 │
                            │                                                  │
  Claude Code / Gemini CLI ─┼──────────────────►  mcp-server                    │
  (รันในเครื่อง ต่อตรง)      └──────────────────────────────────────────────────┘
```

ข้อสังเกตที่สำคัญที่สุดของ workshop นี้: **`mcp-server` ไม่รู้จัก OpenAI เลย**
มันเป็นแค่ HTTP server ตัวหนึ่ง — `tunnel-client` คือท่อที่ถอดเปลี่ยนได้

---

## Lab 0 — เตรียมเครื่อง (5 นาที)

```bash
git clone https://github.com/monthop-gmail/secure-mcp-tunnel-workshop.git
cd secure-mcp-tunnel-workshop
cp .env.example .env
docker --version && docker compose version
```

สำรวจโครงสร้าง:

| ไฟล์ | ทำอะไร |
| --- | --- |
| `mcp-server/server.py` | MCP server ~150 บรรทัด (tools + bearer auth) |
| `docker-compose.yml` | สแตกเต็ม: mcp-server + tunnel-client + profile เสริม |
| `docker-compose.mcp.yml` | MCP server ล้วน ๆ ไม่มีท่อ |
| `workspace/` | โฟลเดอร์ที่ AI จะเข้ามาอ่าน/เขียน |

---

## Lab 1 — รัน MCP server เดี่ยว ๆ แล้วคุยกับมันตรง ๆ (15 นาที)

ยังไม่ต้องมี key ของ OpenAI ใด ๆ ทั้งสิ้น

```bash
docker compose -f docker-compose.mcp.yml up -d --build
docker compose -f docker-compose.mcp.yml ps        # ต้องขึ้น healthy
curl -s http://127.0.0.1:8090/healthz               # ok
```

**1.1 จับมือ (initialize)** — ทุก MCP session เริ่มแบบนี้

```bash
curl -s -H 'Content-Type: application/json' \
     -H 'Accept: application/json, text/event-stream' \
     -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"1"}}}' \
     http://127.0.0.1:8090/mcp
```

จะได้ `serverInfo` + `capabilities` กลับมาในรูปแบบ SSE (`event: message` / `data: {...}`)

**1.2 ถามว่ามี tool อะไรบ้าง**

```bash
curl -s -H 'Content-Type: application/json' \
     -H 'Accept: application/json, text/event-stream' \
     -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
     http://127.0.0.1:8090/mcp
```

**1.3 เรียก tool จริง**

```bash
curl -s -H 'Content-Type: application/json' \
     -H 'Accept: application/json, text/event-stream' \
     -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"write_file","arguments":{"path":"lab1.txt","content":"สวัสดีจาก MCP"}}}' \
     http://127.0.0.1:8090/mcp
cat workspace/lab1.txt
```

> 💡 **จุดที่ต้องเก็บให้ได้**: MCP ก็แค่ JSON-RPC ธรรมดา ไม่มีเวทมนตร์
> ใครยิง HTTP ได้ก็เป็น MCP client ได้

**ลองพัง (ตั้งใจ)** — ยิง path นอก workspace ดู:

```bash
curl -s -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
     -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"read_file","arguments":{"path":"../../etc/passwd"}}}' \
     http://127.0.0.1:8090/mcp
```

ต้องโดน `path escapes the workspace` — ดูโค้ดฟังก์ชัน `_resolve()` ใน `server.py` ว่ากันยังไง

---

## Lab 2 — ต่อกับ AI agent ที่รันในเครื่อง (10 นาที)

MCP server ตัวเดิม ไม่ต้องแก้อะไรเลย เลือกอย่างน้อยหนึ่งตัว:

**Claude Code**
```bash
claude mcp add --transport http workspace http://127.0.0.1:8090/mcp
claude mcp list
```

**Gemini CLI** — `~/.gemini/settings.json`
```json
{
  "mcpServers": {
    "workspace": { "httpUrl": "http://127.0.0.1:8090/mcp", "timeout": 30000 }
  }
}
```

**Codex CLI / Cursor / VS Code / n8n** — ใส่ URL เดียวกันในช่อง HTTP MCP server

แล้วลองสั่งเป็นภาษาคน: *"list files in the workspace แล้วสร้างไฟล์ note.md ให้หน่อย"*

> 💡 **จุดที่ต้องเก็บให้ได้**: เขียน MCP server ครั้งเดียว ใช้ได้ทุก agent
> — นี่คือเหตุผลที่ MCP เกิดมา

---

## Lab 3 — เปิดท่อให้ ChatGPT เข้ามาถึง (20 นาที)

Lab 2 ทำได้เพราะ agent อยู่ในเครื่องเดียวกัน แต่ **ChatGPT รันอยู่บนคลาวด์ OpenAI**
จะเรียก `127.0.0.1` ของเราไม่ได้เด็ดขาด → ต้องมีท่อ

**3.1 เตรียมค่า** (ต้องใช้สิทธิ์ Tunnels **Read + Use**)

| ค่า | เอามาจาก |
| --- | --- |
| `CONTROL_PLANE_TUNNEL_ID` | https://platform.openai.com/settings/organization/tunnels |
| `CONTROL_PLANE_API_KEY` | https://platform.openai.com/settings/organization/api-keys (runtime key ไม่ใช่ admin key) |

ใส่ลง `.env` แล้วปิดสแตกของ Lab 1 ก่อน (ใช้ port เดียวกัน):

```bash
docker compose -f docker-compose.mcp.yml down
docker compose up -d --build
docker compose logs -f tunnel-client
```

**3.2 อ่าน log ให้เป็น** — ที่ต้องการเห็น:

```
🟢 tunnel-client started  tunnel_url=https://api.openai.com/v1/tunnel/tunnel_xxx  name=...
```

**3.3 เช็คสุขภาพ**

```bash
curl -s http://127.0.0.1:8091/healthz     # live
curl -s http://127.0.0.1:8091/readyz      # ready
curl -s http://127.0.0.1:8091/metrics | grep commands_poll_cycles_total
```

`commands_poll_cycles_total` ต้องเพิ่มขึ้นเรื่อย ๆ = long-poll กับ OpenAI ทำงานอยู่

**3.4 ต่อ connector** — เปิด https://chatgpt.com/#settings/Connectors
เพิ่ม connector ของ tunnel นี้ **ขณะที่ daemon กำลังรัน** แล้วสั่งใน ChatGPT ว่า
*"อ่านไฟล์ทั้งหมดใน workspace แล้วสร้างหน้า HTML สรุปให้หน่อย"*

เปิดอีกจอไว้ดู request วิ่ง:

```bash
docker compose logs -f tunnel-client mcp-server
```

> 💡 **จุดที่ต้องเก็บให้ได้**: ไม่มีการเปิด inbound port แม้แต่พอร์ตเดียว
> ทุกอย่างเป็น outbound HTTPS ที่ firewall องค์กรอนุญาตอยู่แล้ว

---

## Lab 4 — ใส่ auth ก่อนคิดจะเปิดออกนอก (10 นาที)

ตอนนี้ MCP server ยังไม่มีการยืนยันตัวตนเลย ปลอดภัยอยู่เพราะ bind แค่ `127.0.0.1`

```bash
# สร้าง token แล้วใส่ลง .env
openssl rand -hex 32
${EDITOR:-nano} .env        # MCP_AUTH_TOKEN=<ค่าที่ได้>
docker compose up -d
```

ทดสอบสามแบบ:

```bash
TOKEN=$(grep '^MCP_AUTH_TOKEN=' .env | cut -d= -f2)

# ไม่ส่ง token → 401
curl -s -o /dev/null -w '%{http_code}\n' -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
  http://127.0.0.1:8090/mcp

# ส่ง token ถูก → 200
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' http://127.0.0.1:8090/mcp

# /healthz เปิดตลอด (ให้ healthcheck/orchestrator ใช้) → 200
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8090/healthz
```

แล้ว ChatGPT ล่ะยังใช้ได้ไหม? **ได้** — `docker-compose.yml` แนบ header ให้เองด้วยบรรทัดนี้:

```yaml
MCP_EXTRA_HEADERS: "${MCP_AUTH_TOKEN:+Authorization: Bearer ${MCP_AUTH_TOKEN}}"
```

(ไวยากรณ์ `:+` ของ Compose = ใส่ค่านี้เฉพาะเมื่อตัวแปรไม่ว่าง)

ฝั่ง agent ในเครื่องต้องเพิ่ม header เองด้วย เช่น Gemini CLI:

```json
{ "mcpServers": { "workspace": {
    "httpUrl": "http://127.0.0.1:8090/mcp",
    "headers": { "Authorization": "Bearer <token>" } } } }
```

> 💡 **จุดที่ต้องเก็บให้ได้**: `MCP_AUTH_TOKEN` ว่าง = ใครก็อ่าน/เขียนไฟล์ได้
> ห้าม bind `0.0.0.0` หรือเปิด public tunnel ก่อนตั้ง token เด็ดขาด

---

## Lab 5 — เขียน tool ของตัวเอง (15 นาที)

เปิด `mcp-server/server.py` แล้วเติม tool ใหม่ (decorator เดียวจบ):

```python
@mcp.tool()
def count_lines(path: str) -> str:
    """นับจำนวนบรรทัดของไฟล์ในเวิร์กสเปซ"""
    target = _resolve(path)
    if not target.is_file():
        return f"not a file: {path}"
    return f"{path}: {len(target.read_text(encoding='utf-8').splitlines())} lines"
```

สิ่งที่ต้องรู้:

- **docstring คือ description ที่ AI เห็น** — เขียนให้ชัด AI จะเลือก tool ถูก
- **type hints กลายเป็น JSON Schema** ของ arguments อัตโนมัติ
- ทุก path ต้องผ่าน `_resolve()` เสมอ

โหลดใหม่แล้วเช็ค:

```bash
docker compose up -d --build mcp-server
curl -s -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
     -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' http://127.0.0.1:8090/mcp | grep count_lines
```

แล้วสั่ง ChatGPT ว่า *"count lines in lab1.txt"* — ถ้า ChatGPT ยังไม่เห็น tool ใหม่
ให้ refresh connector ใน settings หนึ่งครั้ง

**โจทย์ท้าทาย**: เขียน tool ที่ต่อกับระบบภายในองค์กรจริง เช่น query ฐานข้อมูล read-only,
ดึงสถานะจาก internal API, หรืออ่าน log ของ service — นี่คือคุณค่าจริงของ tunnel

---

## Lab 6 — ท่อทางเลือก: Cloudflare Tunnel (10 นาที)

ท่อของ OpenAI ใช้ได้กับผลิตภัณฑ์ OpenAI เท่านั้น ถ้าต้องให้ **Gemini, Copilot Studio,
n8n cloud หรือเพื่อนร่วมทีม** เข้ามาถึง ต้องใช้ท่อทั่วไป

⚠️ **ทำ Lab 4 ให้เสร็จก่อน** — สองคำสั่งข้างล่างนี้เปิด MCP server ออกอินเทอร์เน็ตจริง

**แบบ quick** (ไม่ต้องมีบัญชี ได้ URL สุ่ม หมดอายุเมื่อปิด):

```bash
docker compose --profile cf-quick up cloudflared-quick
# มองหาบรรทัด https://<สุ่ม>.trycloudflare.com ใน log
```

ทดสอบจากที่ไหนก็ได้ในโลก:

```bash
curl -s -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
     -H 'Accept: application/json, text/event-stream' \
     -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ping","arguments":{}}}' \
     https://<สุ่ม>.trycloudflare.com/mcp
```

ถ้าเครื่องมี `cloudflared` ติดตั้งบน host อยู่แล้ว (เช็คด้วย `cloudflared --version`)
รันตรงจาก host ก็ได้ ไม่ต้องใช้ container — ชี้ไปที่พอร์ตที่ publish ไว้:

```bash
cloudflared tunnel --url http://127.0.0.1:8090
```

**แบบ named** (โดเมนของตัวเอง): สร้าง tunnel ใน Cloudflare Zero Trust dashboard
→ ตั้ง public hostname ให้ชี้ไปที่ service `http://mcp-server:8000` → เอา token ใส่ `.env`

```bash
docker compose --profile cf-named up -d cloudflared
```

### เทียบกันชัด ๆ

| | OpenAI Secure MCP Tunnel | Cloudflare Tunnel |
| --- | --- | --- |
| ใครเข้าถึงได้ | เฉพาะ ChatGPT/Codex/API ใน org ของคุณ | ใครก็ได้ที่รู้ URL |
| auth | API key ของ org (บังคับ) | ต้องจัดการเอง (นี่แหละเหตุผลที่ต้องมี Lab 4) |
| endpoint | `api.openai.com/v1/tunnel/<id>` | URL สาธารณะ |
| เหมาะกับ | ต่อ ChatGPT ให้ทีมภายใน | เปิดให้ AI/บริการเจ้าอื่น |

> 💡 **จุดที่ต้องเก็บให้ได้**: MCP server ตัวเดียวกัน เปลี่ยนแค่ท่อ
> ท่อของ OpenAI ปลอดภัยกว่าโดยปริยายเพราะผูกกับ org — ท่อทั่วไปต้องมาใส่ auth เอง

---

## Lab 7 — debug ให้เป็น (5 นาที)

```bash
docker compose logs -f tunnel-client mcp-server   # ดู request วิ่ง real-time
open http://127.0.0.1:8091/ui                     # admin UI: overview / logs / export
curl -s http://127.0.0.1:8091/metrics | grep commands_poll
```

| อาการใน log | สาเหตุ | แก้ |
| --- | --- | --- |
| `poll failed ... 401 invalid_api_key` | key ผิด/หมดอายุ | สร้าง runtime key ใหม่ |
| `poll failed ... 404` | tunnel id ผิด หรือ key ไม่มีสิทธิ์ tunnel นี้ | เช็คสิทธิ์ Tunnels Read+Use |
| `OAuth discovery failed ... decode protected resource metadata` | **ปกติ** สำหรับ MCP ที่ไม่มี OAuth | ไม่ต้องแก้ |
| `rpc_method=server/discover upstream_status=400` | **ปกติ** ChatGPT จะ fallback ไป `tools/list` เอง | ไม่ต้องแก้ |
| `main channel is required` | ไม่ได้ตั้ง `MCP_SERVER_URL` | เช็ค `.env` |
| `log level requires 'struct-text' or 'json' log format` | ตั้ง `LOG_LEVEL` แต่ลืม `LOG_FORMAT` | ตั้งคู่กันเสมอ |
| MCP ตอบ `401 unauthorized` จาก tunnel | token ฝั่ง server กับ header ไม่ตรง | `docker compose up -d` ใหม่หลังแก้ `.env` |

---

## เก็บกวาด

```bash
docker compose down
docker compose -f docker-compose.mcp.yml down
docker compose --profile cf-quick down
```

`workspace/` กับ `.env` ยังอยู่ (ไม่ถูก commit ขึ้น git อยู่แล้ว)

---

## สรุปที่อยากให้กลับบ้านไป

1. **MCP server = HTTP server ธรรมดา** ที่พูด JSON-RPC — เขียนเองได้ใน 100 บรรทัด
2. **เขียนครั้งเดียว ใช้ได้ทุก agent** ทั้งในเครื่องและบนคลาวด์
3. **ท่อถอดเปลี่ยนได้** — OpenAI tunnel, Cloudflare, หรือไม่ใช้เลย ขึ้นกับว่าใครต้องเรียก
4. **outbound-only คือจุดขายกับฝ่าย security** ไม่ต้องขอเปิด inbound port
5. **auth เป็นของคุณ ไม่ใช่ของท่อ** — ทันทีที่ออกจาก loopback ต้องมี token

## อ่านต่อ

- Secure MCP Tunnels: https://developers.openai.com/api/docs/guides/secure-mcp-tunnels
- tunnel-client (docs/ ในรีโปมีครบทั้ง protocol, deployment, troubleshooting): https://github.com/openai/tunnel-client
- Model Context Protocol: https://modelcontextprotocol.io
