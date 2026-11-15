#!/usr/bin/env python3
"""Mirror ERPNext backups to DigitalOcean Spaces (S3-compatible).

A second off-cluster destination on a different provider from the Nextcloud
copy. Uses the bucket shared with Mattermost (`glia-group`, nyc3) under its own
prefix so the two do not collide.

Usage:
  spaces.py upload <backup_dir> <stamp> <site_slug>
  spaces.py prune <keep_days>

Environment: SPACES_KEY, SPACES_SECRET, SPACES_BUCKET, SPACES_ENDPOINT,
SPACES_REGION (default nyc3), SPACES_PREFIX (default erpnext-backups).
"""

from __future__ import annotations

import glob
import os
import sys
from datetime import datetime, timedelta, timezone

import boto3
from botocore.exceptions import BotoCoreError, ClientError

PREFIX = os.environ.get("SPACES_PREFIX", "erpnext-backups").strip("/")


def client():
    return boto3.client(
        "s3",
        region_name=os.environ.get("SPACES_REGION", "nyc3"),
        endpoint_url=os.environ["SPACES_ENDPOINT"],
        aws_access_key_id=os.environ["SPACES_KEY"],
        aws_secret_access_key=os.environ["SPACES_SECRET"],
    )


def upload(backup_dir: str, stamp: str, site_slug: str) -> int:
    s3 = client()
    bucket = os.environ["SPACES_BUCKET"]
    remote_dir = f"{PREFIX}/{site_slug}/{stamp}"
    files = sorted(glob.glob(os.path.join(backup_dir, f"{stamp}-{site_slug}-*")))
    if not files:
        print(f"[spaces] no files for stamp {stamp}", file=sys.stderr)
        return 1

    for path in files:
        name = os.path.basename(path)
        key = f"{remote_dir}/{name}"
        size = os.path.getsize(path)
        print(f"[spaces] uploading {key} ({size} bytes)")
        s3.upload_file(path, bucket, key)
        head = s3.head_object(Bucket=bucket, Key=key)
        if head["ContentLength"] != size:
            print(
                f"[spaces] SIZE MISMATCH for {key}: local {size}, remote {head['ContentLength']}",
                file=sys.stderr,
            )
            return 1
        print(f"[spaces] verified {key} ({head['ContentLength']} bytes)")
    return 0


def prune(keep_days: int) -> int:
    s3 = client()
    bucket = os.environ["SPACES_BUCKET"]
    cutoff = (datetime.now(timezone.utc) - timedelta(days=keep_days)).strftime("%Y%m%d")
    paginator = s3.get_paginator("list_objects_v2")

    removed = 0
    for page in paginator.paginate(Bucket=bucket, Prefix=f"{PREFIX}/"):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            parts = key.split("/")
            if len(parts) < 4:
                continue
            stamp = parts[2]
            if len(stamp) < 8 or not stamp[:8].isdigit():
                continue
            if stamp[:8] < cutoff:
                s3.delete_object(Bucket=bucket, Key=key)
                removed += 1
                print(f"[spaces] pruned {key}")
    print(f"[spaces] pruned {removed} object(s) older than {keep_days} days")
    return 0


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    command = argv[1]
    try:
        if command == "upload":
            if len(argv) != 5:
                print(__doc__, file=sys.stderr)
                return 2
            return upload(argv[2], argv[3], argv[4])
        if command == "prune":
            keep = int(argv[2]) if len(argv) > 2 else 120
            return prune(keep)
    except (BotoCoreError, ClientError) as exc:
        print(f"[spaces] AWS error: {exc}", file=sys.stderr)
        return 1
    print(f"unknown command {command}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
