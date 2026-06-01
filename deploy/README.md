# Deployment — binary + SQLite + Caddy + OSS backup

Production deployment of new-api on an Aliyun ECS (Hangzhou) as a **systemd-managed
native binary** (no Docker), using **SQLite**, fronted by the existing **Caddy** with
automatic HTTPS, and with the database **backed up to Aliyun OSS** on a daily cron.

| Item | Value |
| --- | --- |
| Host | `root@47.98.197.148` (ECS `i-bp10sr2v2igzykyrvsom`, cn-hangzhou) |
| Domain | `llm.hupan.info` (ICP 浙ICP备2025214951号-1) |
| App port | `127.0.0.1:3000` (not exposed publicly; Caddy proxies it) |
| Database | SQLite at `/opt/new-api/one-api.db` |
| Backups | `oss://zp-brain/llm.hupan.info/db-backup/`, daily 03:00, 14-day retention |

## 1. Build the binary (local machine)

```bash
deploy/build.sh
# -> build/new-api-linux-amd64
```

Both frontends are embedded, so `bun` is required locally. The build cross-compiles
for linux/amd64 with `CGO_ENABLED=0` (the SQLite driver is pure Go).

## 2. Provision the server

```bash
ssh root@47.98.197.148 'apt-get update && apt-get install -y sqlite3 && mkdir -p /opt/new-api/logs /opt/new-api/backups'

# binary
scp build/new-api-linux-amd64 root@47.98.197.148:/opt/new-api/new-api
ssh root@47.98.197.148 'chmod +x /opt/new-api/new-api'

# env + systemd unit
scp deploy/new-api.env.example root@47.98.197.148:/opt/new-api/.env   # then edit, set SESSION_SECRET
scp deploy/new-api.service     root@47.98.197.148:/etc/systemd/system/new-api.service
ssh root@47.98.197.148 'systemctl daemon-reload && systemctl enable --now new-api && systemctl status new-api --no-pager'
```

Verify locally on the box:

```bash
ssh root@47.98.197.148 'curl -s http://127.0.0.1:3000/api/status'
```

## 3. DNS

`llm.hupan.info` A record -> `47.98.197.148` (created via Aliyun alidns).

```bash
aliyun alidns AddDomainRecord --DomainName hupan.info --RR llm --Type A --Value 47.98.197.148
```

## 4. Caddy (shared with existing instance)

Append `deploy/Caddyfile.snippet` to `/etc/caddy/Caddyfile`, then:

```bash
ssh root@47.98.197.148 'systemctl reload caddy'
```

Caddy issues and renews the HTTPS certificate automatically once DNS resolves.

## 5. OSS backup

Install ossutil v2 and configure credentials **once**:

```bash
ssh root@47.98.197.148
cd /tmp
curl -fsSL -o ossutil.zip https://gosspublic.alicdn.com/ossutil/v2/2.3.0/ossutil-2.3.0-linux-amd64.zip
echo "3ae4d9fc85a7a6e9f5654d1599766f1a3a42a3692870887b5ae9338d582ef65a  ossutil.zip" | sha256sum -c -
unzip -o ossutil.zip && install -m 0755 ossutil-2.3.0-linux-amd64/ossutil /usr/local/bin/ossutil

# configure credentials (ossutil v2 uses signature v4 — region is REQUIRED).
# Use a RAM-user AccessKey scoped to bucket zp-brain if possible.
ossutil config   # set: region=cn-hangzhou, AccessKeyID, AccessKeySecret
```

`backup.sh` uploads via the internal endpoint `oss-cn-hangzhou-internal.aliyuncs.com`
(no public traffic charge, since the ECS and bucket are both in cn-hangzhou).

Deploy the backup script and cron:

```bash
scp deploy/backup.sh root@47.98.197.148:/opt/new-api/backup.sh
ssh root@47.98.197.148 'chmod +x /opt/new-api/backup.sh'
# test one run
ssh root@47.98.197.148 '/opt/new-api/backup.sh'
# schedule daily at 03:00
ssh root@47.98.197.148 'echo "0 3 * * * /opt/new-api/backup.sh >> /opt/new-api/backups/backup.log 2>&1" | crontab -'
```

`backup.sh` takes a consistent online snapshot (`sqlite3 .backup`, WAL-safe),
gzips it, uploads to `oss://zp-brain/llm.hupan.info/db-backup/`, and prunes local and
remote copies older than 14 days. Remote pruning only matches our own
`one-api-YYYYmmdd-HHMMSS.db.gz` objects under the prefix.

### Restore

```bash
ossutil cp oss://zp-brain/llm.hupan.info/db-backup/one-api-YYYYmmdd-HHMMSS.db.gz ./restore.db.gz -e oss-cn-hangzhou.aliyuncs.com
gunzip restore.db.gz
systemctl stop new-api
cp restore.db /opt/new-api/one-api.db
systemctl start new-api
```

## 6. Upgrades

Rebuild locally, copy the new binary over, restart:

```bash
deploy/build.sh
scp build/new-api-linux-amd64 root@47.98.197.148:/opt/new-api/new-api.new
ssh root@47.98.197.148 'systemctl stop new-api && mv /opt/new-api/new-api.new /opt/new-api/new-api && chmod +x /opt/new-api/new-api && systemctl start new-api'
```

## 7. Per-colleague API usage tracking

Built in — no code change needed:

1. Log in as `root` (default password `123456`) and **change the password immediately**.
2. Create one **user** per colleague (Users page), or issue one **token** per colleague
   under a shared account (Tokens page). One token per person gives the cleanest
   per-person attribution.
3. View usage:
   - **Dashboard / 数据看板** — per-period quota and request counts.
   - **Logs / 日志** — every request with user, token, model, prompt/completion
     tokens and the quota charged. Filter by user or token to get each colleague's
     consumption.
