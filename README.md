# mydrive-mcp-tunnel-workshop

ต่อ **MCP server ในเครื่อง** เข้ากับ **ChatGPT / Codex** ด้วย
[OpenAI Secure MCP Tunnel](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels)
บน Docker Compose — **ไม่ต้องเปิด inbound port**, ไม่ต้องมี public IP, ไม่ต้องขอ firewall rule

MCP server ในรีโปนี้ไม่ผูกกับค่ายไหน จะเอาไปใช้กับ **Claude Code, Gemini CLI, Codex CLI,
Cursor, n8n** หรือโค้ดที่เขียนเองก็ได้ — ท่อเป็นแค่ส่วนเสริมที่ถอดเปลี่ยนได้

> 📚 **สอน/เรียนเป็นขั้นตอน → [WORKSHOP.md](WORKSHOP.md)** (7 labs, ~90 นาที)

```
                            ┌──────────────── เครื่องของคุณ ────────────────┐
  ChatGPT / Codex  ────►    │  tunnel-client  ──►  mcp-server  ──►  ./workspace │
  (คลาวด์ OpenAI)  ◄════════│  outbound HTTPS เท่านั้น                          │
                            │                                                  │
  Claude Code / Gemini CLI ─┼──────────────────►  mcp-server (ต่อตรง)           │
                            └──────────────────────────────────────────────────┘
```

## โครงสร้าง

| ไฟล์ / โฟลเดอร์ | หน้าที่ |
| --- | --- |
| `docker-compose.yml` | สแตกเต็ม: `mcp-server` + `tunnel-client` + profile `stub` / `cf-quick` / `cf-named` |
| `docker-compose.mcp.yml` | MCP server ล้วน ๆ ไม่มีท่อ (ใช้กับ agent ในเครื่อง) |
| `mcp-server/server.py` | MCP server ตัวอย่าง ~150 บรรทัด (FastMCP + bearer auth) |
| `workspace/` | โฟลเดอร์ที่ AI เข้ามาอ่าน/เขียน (mount ที่ `/workspace`) |
| `setup.sh` | ติดตั้ง/รัน/เช็ค/ปิด ให้จบในคำสั่งเดียว |
| `.env` | ค่าลับทั้งหมด (ไม่ถูก commit) — คัดลอกจาก `.env.example` |

Tools ที่มีให้: `list_files`, `read_file`, `write_file`, `search_text`, `ping`
ทุก path ถูก resolve แล้วบังคับให้อยู่ใน `/workspace` เท่านั้น (กัน path traversal)

---

## เร็วที่สุด: `./setup.sh`

```bash
git clone https://github.com/monthop-gmail/mydrive-mcp-tunnel-workshop.git
cd mydrive-mcp-tunnel-workshop
./setup.sh
```

สคริปต์จะตรวจ docker → สร้าง `.env` → หาพอร์ตว่าง → ถามว่าจะรันโหมดไหน → สร้าง token →
build/up → ยิง smoke test → พิมพ์คำสั่งต่อ agent ให้พร้อมคัดลอก

```bash
./setup.sh --mcp-only --auth -y   # MCP server + auth ไม่ต้องถาม (ไม่ต้องมี key ของ OpenAI)
./setup.sh --full                 # สแตกเต็ม (ถาม tunnel id + API key ถ้ายังไม่มีใน .env)
./setup.sh --status               # สถานะ + smoke test
./setup.sh --down                 # ปิดทุกสแตก
```

ถ้าอยากเข้าใจทีละขั้นว่าแต่ละคำสั่งทำอะไร ให้ทำมือตาม 3 แบบข้างล่างนี้แทน

## ทำมือ — 3 แบบ

### A. MCP server อย่างเดียว (ไม่ต้องมี key อะไรเลย)

```bash
cp .env.example .env
docker compose -f docker-compose.mcp.yml up -d --build
curl -s http://127.0.0.1:8090/healthz     # ok
```

ต่อกับ agent ในเครื่อง:

```bash
# Claude Code
claude mcp add --transport http workspace http://127.0.0.1:8090/mcp
```

```jsonc
// Gemini CLI — ~/.gemini/settings.json  (httpUrl = streamable HTTP, url = SSE)
{ "mcpServers": { "workspace": { "httpUrl": "http://127.0.0.1:8090/mcp", "timeout": 30000 } } }
```

Codex CLI / Cursor / VS Code / n8n ก็ใส่ URL เดียวกัน

### B. สแตกเต็ม — ให้ ChatGPT เข้ามาถึง

1. สร้าง tunnel: https://platform.openai.com/settings/organization/tunnels → ได้ `tunnel_...`
2. สร้าง **runtime** API key (ไม่ใช่ admin key) สิทธิ์ Tunnels **Read + Use**:
   https://platform.openai.com/settings/organization/api-keys
3. ใส่ทั้งสองค่าลง `.env` แล้ว

```bash
docker compose up -d --build
docker compose logs -f tunnel-client        # รอบรรทัด 🟢 tunnel-client started
```

4. เพิ่ม connector ที่ https://chatgpt.com/#settings/Connectors **ขณะที่ daemon กำลังรัน**

### C. เช็คแค่ว่า key/tunnel id ใช้ได้ไหม

```bash
docker compose --profile stub run --rm tunnel-stub
```

ใช้ demo MCP stub ที่ฝังมาในตัว client — ไม่แตะ MCP server ของเรา

---

## ใส่ auth (จำเป็นถ้าจะออกจาก loopback)

```bash
openssl rand -hex 32                  # เอาค่าไปใส่ MCP_AUTH_TOKEN ใน .env
docker compose up -d
```

- ทุก request ต้องมี `Authorization: Bearer <token>` ยกเว้น `/healthz`
- `tunnel-client` แนบ header ให้อัตโนมัติผ่าน `MCP_EXTRA_HEADERS` เมื่อ token ไม่ว่าง
- ฝั่ง agent ในเครื่องต้องใส่ header เอง เช่น Gemini CLI:

```jsonc
{ "mcpServers": { "workspace": {
    "httpUrl": "http://127.0.0.1:8090/mcp",
    "headers": { "Authorization": "Bearer <token>" } } } }
```

⚠️ `MCP_AUTH_TOKEN` ว่าง = ใครยิงถึงก็อ่าน/เขียน/ลบไฟล์ใน `workspace/` ได้
อย่าตั้ง `MCP_BIND_ADDR=0.0.0.0` หรือเปิด public tunnel ก่อนตั้ง token

---

## ท่อทางเลือก: Cloudflare Tunnel

ท่อของ OpenAI ใช้ได้กับผลิตภัณฑ์ OpenAI เท่านั้น ถ้าต้องให้ AI เจ้าอื่นหรือคนนอกเข้าถึง:

```bash
# URL สุ่มชั่วคราว ไม่ต้องมีบัญชี (ตั้ง MCP_AUTH_TOKEN ก่อน!)
docker compose --profile cf-quick up cloudflared-quick

# โดเมนของตัวเอง: ตั้ง route ใน Cloudflare Zero Trust ให้ชี้มาที่ http://mcp-server:8000
docker compose --profile cf-named up -d cloudflared
```

| | OpenAI Secure MCP Tunnel | Cloudflare Tunnel |
| --- | --- | --- |
| ใครเข้าถึงได้ | เฉพาะ ChatGPT/Codex/API ใน org ของคุณ | ใครก็ได้ที่รู้ URL |
| auth | API key ของ org (บังคับ) | ต้องจัดการเอง |
| เหมาะกับ | ต่อ ChatGPT ให้ทีมภายใน | เปิดให้ AI/บริการเจ้าอื่น |

---

## พอร์ต

publish เฉพาะ `127.0.0.1` โดยดีฟอลต์ ปรับได้ใน `.env`

| service | host | container |
| --- | --- | --- |
| `mcp-server` | `${MCP_BIND_ADDR}:${MCP_HOST_PORT}` = `127.0.0.1:8090` | `8000` — `/mcp`, `/healthz` |
| `tunnel-client` | `127.0.0.1:8091` | `8080` — `/healthz`, `/readyz`, `/metrics`, `/ui` |

`ALLOW_REMOTE_UI=true` จำเป็นเพราะ request จาก host เข้ามาทาง docker bridge ไม่ใช่ loopback
ของ container — ยังปลอดภัยเพราะพอร์ตผูกกับ `127.0.0.1` ของ host อยู่แล้ว

## Log ที่เจอบ่อย

- `🟢 tunnel-client started ... tunnel_url=https://api.openai.com/v1/tunnel/<id>` = ต่อสำเร็จ
- `WARN OAuth discovery failed ... decode protected resource metadata` = **ปกติ**
  สำหรับ MCP server ที่ไม่มี OAuth (client probe `/.well-known/...` แล้วได้ 404)
- `rpc_method=server/discover upstream_status=400` = **ปกติ** ChatGPT จะ fallback ไป `tools/list`
- `poll failed ... 401 invalid_api_key` = key ผิด/หมดอายุ/ไม่มีสิทธิ์ Tunnels Use
- `configure tunnel-client: log level requires 'struct-text' or 'json' log format`
  = ตั้ง `LOG_LEVEL` โดยไม่ตั้ง `LOG_FORMAT`

เช็คว่า poll วิ่งอยู่จริง:

```bash
curl -s http://127.0.0.1:8091/metrics | grep commands_poll_cycles_total
```

## เปลี่ยนไปใช้ MCP server ตัวอื่น

แก้ `MCP_SERVER_URL` ของ service `tunnel-client` ให้ชี้ไปที่ MCP server ตัวอื่นได้เลย
(ต้องอยู่ใน docker network เดียวกัน หรือใช้ `host.docker.internal` + `extra_hosts`)

ถ้าเป็น MCP แบบ stdio ให้ใช้ `MCP_COMMAND` แทน — แต่คำสั่งนั้นต้องมีอยู่ใน image ของ
tunnel-client (image ทางการมีแค่ binary) จึงมักต้อง build image เอง

## License

MIT
