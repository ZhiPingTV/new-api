#!/usr/bin/env bash
#
# new-api SQLite backup -> Aliyun OSS
#
# - Takes a consistent ONLINE snapshot with `sqlite3 .backup` (safe while the
#   service is running; handles WAL correctly — never just `cp` a live DB).
# - Compresses it and uploads to oss://$OSS_BUCKET/$OSS_PREFIX/.
# - Prunes local copies and remote copies older than $RETENTION_DAYS.
#   Remote pruning ONLY touches objects under $OSS_PREFIX whose name matches
#   our own "one-api-YYYYmmdd-HHMMSS.db.gz" pattern, so other data in the
#   bucket is never affected.
#
# Schedule from cron, e.g. daily at 03:00 (see deploy/README.md):
#   0 3 * * * /opt/new-api/backup.sh >> /opt/new-api/backups/backup.log 2>&1
#
# OSS credentials come from ossutil's config file (~/.ossutilconfig by default),
# created once with:  ossutil config   (set region=cn-hangzhou, AK id/secret)
#
# ossutil v2 uses signature v4 and REQUIRES a region. The ECS and the bucket are
# both in cn-hangzhou, so we default to the internal endpoint
# (oss-cn-hangzhou-internal.aliyuncs.com) — faster and free of public traffic
# charges. Override OSS_ENDPOINT to a public endpoint if running off-Aliyun.

set -euo pipefail

# ---- configuration (override via /opt/new-api/backup.env) -------------------
DB_FILE="${DB_FILE:-/opt/new-api/one-api.db}"
LOCAL_DIR="${LOCAL_DIR:-/opt/new-api/backups}"
# NOTE: zp-brain is a SHARED bucket. Keep everything for this deployment under a
# dedicated top-level prefix named after the domain, so it never mixes with other
# projects' data. Backups live under <domain>/db-backup/.
OSS_BUCKET="${OSS_BUCKET:-zp-brain}"
OSS_PREFIX="${OSS_PREFIX:-llm.hupan.info/db-backup}"
OSS_REGION="${OSS_REGION:-cn-hangzhou}"
OSS_ENDPOINT="${OSS_ENDPOINT:-oss-cn-hangzhou-internal.aliyuncs.com}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
OSSUTIL="${OSSUTIL:-ossutil}"

ENV_FILE="${ENV_FILE:-/opt/new-api/backup.env}"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

# Hard guard: never run remote prune with an empty prefix.
if [ -z "${OSS_PREFIX// }" ]; then
	echo "FATAL: OSS_PREFIX is empty, refusing to continue" >&2
	exit 1
fi

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

TS="$(date +%Y%m%d-%H%M%S)"
NAME="one-api-${TS}.db"
SNAP="${LOCAL_DIR}/${NAME}"
GZ="${SNAP}.gz"

mkdir -p "$LOCAL_DIR"

if [ ! -f "$DB_FILE" ]; then
	log "FATAL: database not found: $DB_FILE"
	exit 1
fi

# 1) consistent online snapshot
log "snapshotting $DB_FILE -> $SNAP"
sqlite3 "$DB_FILE" ".backup '$SNAP'"

# integrity check on the snapshot before we trust it
if ! sqlite3 "$SNAP" 'PRAGMA integrity_check;' | grep -q '^ok$'; then
	log "FATAL: integrity check failed on snapshot $SNAP"
	rm -f "$SNAP"
	exit 1
fi

# 2) compress
gzip -f "$SNAP"
SIZE="$(du -h "$GZ" | cut -f1)"
log "compressed -> $GZ ($SIZE)"

# 3) upload to OSS
OSS_DEST="oss://${OSS_BUCKET}/${OSS_PREFIX}/${NAME}.gz"
log "uploading -> $OSS_DEST"
"$OSSUTIL" cp -f "$GZ" "$OSS_DEST" --region "$OSS_REGION" -e "$OSS_ENDPOINT" >/dev/null
log "upload ok"

# 4) local retention
find "$LOCAL_DIR" -maxdepth 1 -name 'one-api-*.db.gz' -mtime +"$RETENTION_DAYS" -print -delete \
	| sed 's/^/[prune-local] /' || true

# 5) remote retention — only our own dated objects under the prefix
cutoff="$(date -d "-${RETENTION_DAYS} days" +%Y%m%d 2>/dev/null || true)"
if [ -n "$cutoff" ]; then
	# regex-safe copies of the bucket/prefix (escape every char that is special in ERE)
	esc_bucket="$(printf '%s' "$OSS_BUCKET" | sed 's/[.[\*^$()+?{|]/\\&/g')"
	esc_prefix="$(printf '%s' "$OSS_PREFIX" | sed 's/[.[\*^$()+?{|]/\\&/g')"
	"$OSSUTIL" ls "oss://${OSS_BUCKET}/${OSS_PREFIX}/" --region "$OSS_REGION" -e "$OSS_ENDPOINT" 2>/dev/null \
		| grep -oE "oss://${esc_bucket}/${esc_prefix}/one-api-[0-9]{8}-[0-9]{6}\.db\.gz" \
		| while read -r obj; do
			d="$(echo "$obj" | grep -oE 'one-api-[0-9]{8}' | grep -oE '[0-9]{8}')"
			if [ -n "$d" ] && [ "$d" -lt "$cutoff" ]; then
				log "prune-remote $obj"
				"$OSSUTIL" rm "$obj" --region "$OSS_REGION" -e "$OSS_ENDPOINT" -f >/dev/null || true
			fi
		done
fi

log "backup complete"
