# Backup health check — installed as a Server Script (Scheduler Event, daily).
#
# The backup CronJob writes sites/<site>/private/backups/last_run.json on every
# run (status ok/failed + the stage it reached). This check runs on the Frappe
# scheduler and emails info@glia.org when that marker is missing, reports a
# failure, or is older than 26h — i.e. when a scheduled backup silently stopped.
#
# It deliberately does not verify the remote copies: the backup job fails hard
# if either upload or size check fails, so a fresh "ok" marker means both copies
# were verified at write time.
#
# Install with backup/apply_health_check.py (see README §2).

import json
import os
from datetime import datetime, timezone

SITE = "asset.glia.org"
MARKER = "/home/frappe/frappe-bench/sites/" + SITE + "/private/backups/last_run.json"
MAX_AGE_HOURS = 26
ALERT_TO = ["info@glia.org"]
CACHE_KEY = "glia:backup_health_alert"


def _alert(subject, detail):
	if frappe.cache().get_value(CACHE_KEY):
		return "alert already sent recently"
	frappe.cache().set_value(CACHE_KEY, 1, expires_in_sec=12 * 3600)
	frappe.sendmail(
		recipients=ALERT_TO,
		subject=subject,
		message=(
			"<p>" + detail + "</p>"
			"<p>Backups: <code>kubectl -n erpnext get jobs | grep erpnext-backup</code>, "
			"runbook <code>helm-erpnext/backup/README.md</code>.</p>"
		),
		now=True,
	)
	frappe.log_error(detail, subject)
	return "alert sent"


if not os.path.exists(MARKER):
	result = _alert(
		"[Glia] ERPNext backups: no backup has run",
		f"No status marker at <code>{MARKER}</code>: no backup has completed since the "
		"CronJob was installed, or the sites volume was replaced.",
	)
else:
	try:
		state = json.load(open(MARKER))
	except Exception:
		state = {"status": "unreadable"}

	status = (state.get("status") or "").lower()
	if status != "ok":
		result = _alert(
			"[Glia] ERPNext backup FAILED",
			f"Last backup status: <b>{status or 'unknown'}</b>, stage: "
			f"<b>{state.get('stage') or '?'}</b>, at {state.get('finished') or '?'}.",
		)
	else:
		finished = state.get("finished") or ""
		age_hours = None
		try:
			stamp = datetime.fromisoformat(finished.replace("Z", "+00:00"))
			if stamp.tzinfo is None:
				stamp = stamp.replace(tzinfo=timezone.utc)
			age_hours = (datetime.now(timezone.utc) - stamp).total_seconds() / 3600.0
		except Exception:
			age_hours = None

		if age_hours is None:
			result = _alert(
				"[Glia] ERPNext backup status unreadable",
				f"The marker at <code>{MARKER}</code> has no parseable timestamp.",
			)
		elif age_hours > MAX_AGE_HOURS:
			result = _alert(
				"[Glia] ERPNext backup is stale",
				f"The newest backup ({state.get('stamp')}) finished "
				f"{age_hours:.1f} h ago, expected within {MAX_AGE_HOURS} h.",
			)
		else:
			result = f"ok ({age_hours:.1f} h old, stamp {state.get('stamp')})"

print(result)
