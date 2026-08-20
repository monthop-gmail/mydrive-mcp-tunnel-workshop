# test-chatgpt-local — OpenAI Secure MCP Tunnel (Docker Compose)

ต่อ MCP server ที่รันในเครื่องนี้เข้ากับ ChatGPT / Codex / Responses API
ผ่าน **Secure MCP Tunnel** ของ OpenAI โดย **ไม่ต้องเปิด inbound port** ใดๆ
— `tunnel-client` วิ่งออกขาเดียว (outbound HTTPS) ไปที่ `api.openai.com`
แล้ว poll งานกลับมายิงเข้า MCP server ใน docker network

- Guide: https://developers.openai.com/api/docs/guides/secure-mcp-tunnels
- Client: https://github.com/openai/tunnel-client

```
ChatGPT / Codex  ──►  OpenAI tunnel endpoint  ◄══ outbound HTTPS ══  tunnel-client ──►  mcp-server ──►  ./workspace
                                                                     (container)         (container)
```

## โครงสร้าง

| ไฟล์ / โฟลเดอร์ | หน้าที่ |
| --- | --- |
| `docker-compose.yml` | สแตกทั้งหมด: `mcp-server`, `tunnel-client`, และ `tunnel-stub` (profile `stub`) |
| `.env` | ใส่ `CONTROL_PLANE_TUNNEL_ID` + `CONTROL_PLANE_API_KEY` ที่นี่ (chmod 600, อยู่ใน .gitignore) |
| `.env.example` | ตัวอย่างค่า config พร้อมลิงก์หน้าที่ใช้ขอค่าแต่ละตัว |
| `mcp-server/` | MCP server ตัวอย่าง (Python + FastMCP) เสิร์ฟผ่าน streamable HTTP ที่ `/mcp` |
| `workspace/` | โฟลเดอร์ที่ MCP server เปิดให้ ChatGPT อ่าน/เขียน (mount เข้า container ที่ `/workspace`) |

Tools ที่ MCP server ให้: `list_files`, `read_file`, `write_file`, `search_text`, `ping`
ทุก path ถูก resolve แล้วเช็คว่าต้องอยู่ใน `/workspace` เท่านั้น (กัน path traversal)

## ขั้นตอนใช้งาน

### 1. สร้าง tunnel + runtime API key

1. สร้าง tunnel: https://platform.openai.com/settings/organization/tunnels → ได้ `tunnel_...`
2. สร้าง **runtime** API key (ไม่ใช่ admin key): https://platform.openai.com/settings/organization/api-keys
   — principal ต้องมีสิทธิ์ Tunnels **Read + Use**
3. ใส่ทั้งสองค่าลง `.env`:

```bash
cd /opt/docker-test/test-chatgpt-local
${EDITOR:-nano} .env
```

### 2. รันสแตก

```bash
docker compose up -d --build
docker compose ps
docker compose logs -f tunnel-client
```

log ที่ต้องการเห็นคือไม่มี `poll failed` — ถ้าเห็น `401 invalid_api_key` แปลว่า key ผิด,
ถ้าเห็น `404` แปลว่า tunnel id ผิดหรือ key ไม่มีสิทธิ์กับ tunnel นั้น

### 3. เช็คสุขภาพ

```bash
curl -s http://127.0.0.1:8091/healthz    # tunnel-client
curl -s http://127.0.0.1:8091/readyz
curl -s http://127.0.0.1:8091/metrics | head
xdg-open http://127.0.0.1:8091/ui        # admin UI (overview / logs / export)
```

ยิง MCP server ตรงๆ เพื่อดูว่า tools ทำงาน (ไม่ผ่าน tunnel):

```bash
curl -s -H 'Content-Type: application/json' \
     -H 'Accept: application/json, text/event-stream' \
     -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ping","arguments":{}}}' \
     http://127.0.0.1:8090/mcp
```

### 4. ต่อกับ ChatGPT

เปิด https://chatgpt.com/#settings/Connectors แล้วเพิ่ม connector ของ tunnel นี้
**ขณะที่ `tunnel-client` กำลังรันและ healthy** — connector discovery และทุก MCP call
ต้องการให้ daemon รันค้างไว้ตลอด

## ทดสอบเฉพาะการเชื่อมต่อ (ไม่ใช้ MCP server ของเรา)

`tunnel-client` มี demo MCP stub ในตัว ใช้พิสูจน์ว่า key/tunnel id/egress ถูกต้อง:

```bash
docker compose --profile stub run --rm tunnel-stub
```

## พอร์ต

publish เฉพาะ `127.0.0.1` เท่านั้น (ไม่ออกเน็ต) — แก้ได้ใน `.env`

| service | host | container |
| --- | --- | --- |
| `mcp-server` | `127.0.0.1:8090` | `8000` (`/mcp`, `/healthz`) |
| `tunnel-client` | `127.0.0.1:8091` | `8080` (`/healthz`, `/readyz`, `/metrics`, `/ui`) |

> `ALLOW_REMOTE_UI=true` ใน compose จำเป็นเพราะ request จาก host เข้ามาทาง docker bridge
> ไม่ใช่ loopback ของ container — ปลอดภัยเพราะ port ผูกกับ `127.0.0.1` ของ host อยู่แล้ว

## หมายเหตุการ config

- `LOG_LEVEL` ต้องมาคู่กับ `LOG_FORMAT` (`struct-text` หรือ `json`) ไม่งั้น client จะไม่ start
- `MCP_STARTUP_WAIT_TIMEOUT=60s` ให้ client รอ MCP listener พร้อมก่อน poll ครั้งแรก
- ไฟล์ที่เขียนลง `workspace/` จะเป็นของ uid/gid ตาม `PUID`/`PGID` ใน `.env` (default 1001 = admin)
- pin version ของ image ไว้ที่ `TUNNEL_CLIENT_VERSION` — อัปเดตได้จาก
  https://github.com/openai/tunnel-client/releases

## Log ที่เจอบ่อย

- `🟢 tunnel-client started ... tunnel_url=https://api.openai.com/v1/tunnel/<id>` = ต่อสำเร็จ
- `WARN OAuth discovery failed ... decode protected resource metadata` = ปกติ
  สำหรับ MCP server ที่ไม่มี OAuth (ตัวอย่างในโฟลเดอร์นี้) client จะ probe
  `/.well-known/oauth-protected-resource` แล้วได้ 404 กลับมา — ไม่กระทบการใช้งาน
- `poll failed; backing off ... 401 invalid_api_key` = key ผิด/หมดอายุ/ไม่มีสิทธิ์ Tunnels Use
- `configure tunnel-client: log level requires 'struct-text' or 'json' log format`
  = ตั้ง `LOG_LEVEL` โดยไม่ตั้ง `LOG_FORMAT`

เช็คว่า poll วิ่งอยู่จริง:

```bash
curl -s http://127.0.0.1:8091/metrics | grep commands_poll_cycles_total
```

## เปลี่ยนไปใช้ MCP server ตัวอื่น

แก้ `MCP_SERVER_URL` ของ service `tunnel-client` ให้ชี้ไปที่ MCP server ตัวอื่นได้เลย
(ต้องอยู่ใน docker network เดียวกัน หรือใช้ `host.docker.internal` / IP ของ host)
เช่น `MCP_SERVER_URL: http://host.docker.internal:8000/mcp` แล้วเพิ่ม
`extra_hosts: ["host.docker.internal:host-gateway"]`

ถ้าจะใช้ MCP แบบ stdio ให้ใช้ `MCP_COMMAND` แทน `MCP_SERVER_URL` — แต่คำสั่งนั้น
ต้องมีอยู่ใน image ของ tunnel-client (image ทางการมีแค่ตัว binary) จึงมักต้อง build image เอง
