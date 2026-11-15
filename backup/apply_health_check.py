"""Install/update the backup health check Server Script.

The script body lives in backup/health_check.py (source of truth in this repo);
this runner upserts it as a *Scheduler Event* Server Script so the Frappe
scheduler executes it daily.

Usage (in the pod):
    kubectl -n erpnext cp backup/health_check.py \\
        <pod>:/tmp/health_check.py
    kubectl -n erpnext cp backup/apply_health_check.py \\
        <pod>:/tmp/apply_health_check.py
    kubectl -n erpnext exec deploy/erpnext-gunicorn -- bash -lc \\
        'cd /home/frappe/frappe-bench && bench --site asset.glia.org console < /tmp/apply_health_check.py'
"""

import frappe

NAME = "Backup Health Check"
SCRIPT_FILE = "/tmp/health_check.py"

body = open(SCRIPT_FILE, encoding="utf-8").read()

if frappe.db.exists("Server Script", NAME):
	doc = frappe.get_doc("Server Script", NAME)
else:
	doc = frappe.new_doc("Server Script")
	doc.name = NAME

doc.update(
	{
		"name": NAME,
		"script_type": "Scheduler Event",
		"event_frequency": "Daily",
		"disabled": 0,
		"script": body,
	}
)
doc.flags.ignore_permissions = True
if doc.is_new():
	doc.insert(ignore_permissions=True)
else:
	doc.save(ignore_permissions=True)
frappe.db.commit()

print("installed:", doc.name, "| type:", doc.script_type, "| frequency:", doc.event_frequency)
print("script length:", len(doc.script))
