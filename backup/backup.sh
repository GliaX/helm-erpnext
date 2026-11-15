#!/usr/bin/env bash
# ERPNext backup: dump → verify → copy off-cluster (Nextcloud) → mirror to DO
# Spaces → prune → write a status marker the health check reads.
#
# Runs inside the image's bench container, as the frappe user, with the sites
# PVC mounted. See backup/README.md.
set -uo pipefail

SITE="${SITE:-asset.glia.org}"
SITE_SLUG="${SITE//./_}"
BENCH=/home/frappe/frappe-bench
BACKUP_DIR="$BENCH/sites/$SITE/private/backups"
MARKER="$BACKUP_DIR/last_run.json"
LOCAL_KEEP_DAYS="${LOCAL_KEEP_DAYS:-14}"
REMOTE_KEEP_DAYS="${REMOTE_KEEP_DAYS:-120}"
STAGE="start"

mkdir -p "$BACKUP_DIR"

log() { printf '%s [backup] %s\n' "$(date -Is)" "$*"; }

write_marker() {
	python3 - "$MARKER" "$1" "$2" "$STAGE" <<'PY'
import json, sys, datetime
path, status, stamp, stage = sys.argv[1:5]
payload = {
    "status": status,
    "stamp": stamp,
    "stage": stage,
    "finished": datetime.datetime.now(datetime.timezone.utc).isoformat(),
}
json.dump(payload, open(path, "w"), indent=1)
PY
}

fail() {
	STAGE="$1"
	log "FAILED at $STAGE: ${2:-}"
	write_marker failed "" || true
	exit 1
}

trap 'fail "$STAGE" "unexpected error"' ERR

STAGE="bench-backup"
write_marker running ""
log "starting $(hostname)"
cd "$BENCH" || fail "chdir" "$BENCH missing"

bench --site "$SITE" backup --with-files || fail "$STAGE" "bench backup failed"

STAGE="locate"
DB_FILE=$(ls -1t "$BACKUP_DIR"/*-"$SITE_SLUG"-database.sql.gz 2>/dev/null | head -1)
[ -n "$DB_FILE" ] || fail "$STAGE" "no database dump produced"
STAMP=$(basename "$DB_FILE" | sed "s/-$SITE_SLUG-database.sql.gz$//")
log "backup stamp: $STAMP"

STAGE="verify-local"
gzip -t "$DB_FILE" || fail "$STAGE" "database dump is not valid gzip"
for kind in files private-files; do
	TAR="$BACKUP_DIR/$STAMP-$SITE_SLUG-$kind.tar"
	[ -f "$TAR" ] || { log "WARN no $kind archive"; continue; }
	tar -tf "$TAR" >/dev/null || fail "$STAGE" "$kind archive unreadable"
done
log "local integrity OK"

# ---- off-cluster copy #1: Nextcloud (WebDAV) -------------------------------
STAGE="nextcloud"
if [ -n "${NC_URL:-}" ] && [ -n "${NC_USER:-}" ] && [ -n "${NC_PASS:-}" ]; then
	REMOTE_DIR="$NC_URL/remote.php/dav/files/$NC_USER/erpnext-backups/$SITE"
	curl -fsS -u "$NC_USER:$NC_PASS" -X MKCOL "$REMOTE_DIR/" >/dev/null 2>&1 || true
	for FILE in "$BACKUP_DIR/$STAMP-$SITE_SLUG-"*; do
		NAME=$(basename "$FILE")
		SIZE=$(stat -c %s "$FILE")
		curl -fsS --retry 5 --retry-delay 5 --retry-all-errors \
			-u "$NC_USER:$NC_PASS" -T "$FILE" "$REMOTE_DIR/$NAME" \
			|| fail "$STAGE" "upload failed for $NAME"
		REMOTE_SIZE=$(curl -fsSI -u "$NC_USER:$NC_PASS" "$REMOTE_DIR/$NAME" \
			| tr -d '\r' | awk 'tolower($1)=="content-length:" {print $2}' | tail -1)
		[ "$REMOTE_SIZE" = "$SIZE" ] || fail "$STAGE" "size mismatch for $NAME"
		log "nextcloud verified $NAME ($REMOTE_SIZE bytes)"
	done
else
	fail "$STAGE" "Nextcloud credentials missing — both off-cluster copies are required"
fi

# ---- off-cluster copy #2: DigitalOcean Spaces (independent provider) ------
STAGE="spaces"
if [ -n "${SPACES_KEY:-}" ] && [ -n "${SPACES_SECRET:-}" ]; then
	"$BENCH/env/bin/python" /opt/glia-backup/spaces.py upload "$BACKUP_DIR" "$STAMP" "$SITE_SLUG" \
		|| fail "$STAGE" "Spaces mirror failed"
	"$BENCH/env/bin/python" /opt/glia-backup/spaces.py prune "$REMOTE_KEEP_DAYS" \
		|| log "WARN Spaces prune failed"
else
	fail "$STAGE" "Spaces credentials missing — both off-cluster copies are required"
fi

# ---- retention on the PVC + Nextcloud -------------------------------------
STAGE="prune-local"
CUTOFF_LOCAL=$(date -d "-$LOCAL_KEEP_DAYS days" +%Y%m%d)
for FILE in "$BACKUP_DIR"/*-"$SITE_SLUG"-*; do
	[ -e "$FILE" ] || continue
	FSTAMP=$(basename "$FILE" | cut -d- -f1)
	case "$FSTAMP" in
		[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
		*) continue ;;
	esac
	if [ "$FSTAMP" -lt "$CUTOFF_LOCAL" ]; then
		log "pruning local $(basename "$FILE")"
		rm -f "$FILE"
	fi
done

STAGE="prune-nextcloud"
if [ -n "${NC_URL:-}" ] && [ -n "${NC_USER:-}" ] && [ -n "${NC_PASS:-}" ]; then
	CUTOFF_REMOTE=$(date -d "-$REMOTE_KEEP_DAYS days" +%Y%m%d)
	REMOTE_LIST=$(curl -fsS -u "$NC_USER:$NC_PASS" -X PROPFIND -H "Depth: 1" \
		--data '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:getlastmodified/></d:prop></d:propfind>' \
		"$REMOTE_DIR/" 2>/dev/null || true)
	for NAME in $(echo "$REMOTE_LIST" | grep -o '<d:href>[^<]*</d:href>' \
			| sed 's|<d:href>||; s|</d:href>||' | xargs -n1 basename 2>/dev/null || true); do
		FSTAMP=$(echo "$NAME" | cut -d- -f1)
		case "$FSTAMP" in
			[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
			*) continue ;;
		esac
		if [ "$FSTAMP" -lt "$CUTOFF_REMOTE" ]; then
			log "pruning nextcloud $NAME"
			curl -fsS -u "$NC_USER:$NC_PASS" -X DELETE "$REMOTE_DIR/$NAME" >/dev/null || true
		fi
	done
fi

STAGE="done"
write_marker ok "$STAMP"
log "done: $STAMP backed up locally, on Nextcloud and mirrored to Spaces"
