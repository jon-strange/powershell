"""
append_recovery_tags.py
-----------------------
Reads vCenter inventory (spreadsheet1) and an application/server dataset
(spreadsheet2), then appends missing "Recovery Plan Groups" tags to any VM
that lacks one, using an editable RTO → tag mapping CSV.

Usage:
    python append_recovery_tags.py \
        --inventory   spreadsheet1.xlsx \
        --appdata     spreadsheet2.xlsx \
        --mapping     rto_mapping.csv \
        --inv-vm-col  "VM Name" \
        --inv-tag-col "Tags" \
        --app-ci-col  "Configuration Item ID" \
        --app-rto-col "RTO" \
        --output      spreadsheet1_updated.xlsx \
        --audit       audit_log.xlsx

All column-name arguments have sensible defaults (shown above) but can be
overridden if your actual headers differ.
"""

import argparse
import sys
from datetime import datetime

import pandas as pd


TAG_CATEGORY = "Recovery Plan Groups"
TAG_DELIMITER = ";"


def parse_args():
    p = argparse.ArgumentParser(description="Append missing Recovery Plan Groups tags.")
    p.add_argument("--inventory",   default="spreadsheet1.xlsx", help="vCenter inventory file")
    p.add_argument("--appdata",     default="spreadsheet2.xlsx", help="Application/server data file")
    p.add_argument("--mapping",     default="rto_mapping.csv",   help="RTO → Tag mapping CSV")
    p.add_argument("--inv-vm-col",  default="VM Name",                  help="VM name column in inventory")
    p.add_argument("--inv-tag-col", default="Tags",                     help="Tags column in inventory")
    p.add_argument("--app-ci-col",  default="Configuration Item ID",    help="Config Item ID column in appdata")
    p.add_argument("--app-rto-col", default="RTO",                      help="RTO column in appdata")
    p.add_argument("--output",      default="spreadsheet1_updated.xlsx",help="Updated inventory output file")
    p.add_argument("--audit",       default="audit_log.xlsx",           help="Audit log output file")
    return p.parse_args()


def has_recovery_tag(tags_value: str) -> bool:
    """Return True if any semicolon-delimited tag starts with the category name."""
    if pd.isna(tags_value) or str(tags_value).strip() == "":
        return False
    for tag in str(tags_value).split(TAG_DELIMITER):
        if tag.strip().lower().startswith(TAG_CATEGORY.lower() + ":"):
            return True
    return False


def append_tag(existing_tags: str, new_tag: str) -> str:
    """Append new_tag to the end of the existing semicolon-delimited tag string."""
    if pd.isna(existing_tags) or str(existing_tags).strip() == "":
        return new_tag
    return str(existing_tags).rstrip() + f"{TAG_DELIMITER} {new_tag}"


def find_ci_match(vm_name: str, ci_series: pd.Series) -> int | None:
    """
    Return the index of the first CI ID that is a case-insensitive substring
    of vm_name, or None if no match found.
    """
    vm_lower = str(vm_name).lower()
    for idx, ci in ci_series.items():
        if pd.isna(ci):
            continue
        if str(ci).lower() in vm_lower:
            return idx
    return None


def main():
    args = parse_args()

    # ── Load inputs ──────────────────────────────────────────────────────────
    try:
        inv = pd.read_excel(args.inventory, dtype=str)
    except FileNotFoundError:
        sys.exit(f"ERROR: Inventory file not found: {args.inventory}")

    try:
        app = pd.read_excel(args.appdata, dtype=str)
    except FileNotFoundError:
        sys.exit(f"ERROR: App data file not found: {args.appdata}")

    try:
        mapping_df = pd.read_csv(args.mapping, dtype=str)
        rto_map = dict(zip(
            mapping_df["RTO"].str.strip(),
            mapping_df["Tag"].str.strip()
        ))
    except FileNotFoundError:
        sys.exit(f"ERROR: Mapping file not found: {args.mapping}")

    # ── Validate columns ─────────────────────────────────────────────────────
    for col, src in [(args.inv_vm_col, args.inventory),
                     (args.inv_tag_col, args.inventory)]:
        if col not in inv.columns:
            sys.exit(f"ERROR: Column '{col}' not found in {src}.\n"
                     f"Available columns: {list(inv.columns)}")

    for col, src in [(args.app_ci_col, args.appdata),
                     (args.app_rto_col, args.appdata)]:
        if col not in app.columns:
            sys.exit(f"ERROR: Column '{col}' not found in {src}.\n"
                     f"Available columns: {list(app.columns)}")

    # ── Process each VM ───────────────────────────────────────────────────────
    audit_rows = []
    updated_tags = inv[args.inv_tag_col].copy()

    for i, row in inv.iterrows():
        vm_name   = str(row[args.inv_vm_col])
        tags_val  = row[args.inv_tag_col]

        # Already has a Recovery Plan Groups tag — skip
        if has_recovery_tag(tags_val):
            audit_rows.append({
                "VM Name":        vm_name,
                "Status":         "Already tagged",
                "Matched CI ID":  "",
                "RTO Value":      "",
                "Tag Applied":    "",
                "Original Tags":  tags_val,
                "Updated Tags":   tags_val,
            })
            continue

        # Look for a CI ID that is a substring of the VM name
        match_idx = find_ci_match(vm_name, app[args.app_ci_col])

        if match_idx is None:
            audit_rows.append({
                "VM Name":        vm_name,
                "Status":         "No CI match found",
                "Matched CI ID":  "",
                "RTO Value":      "",
                "Tag Applied":    "",
                "Original Tags":  tags_val,
                "Updated Tags":   tags_val,
            })
            continue

        matched_ci  = app.loc[match_idx, args.app_ci_col]
        rto_value   = str(app.loc[match_idx, args.app_rto_col]).strip()

        # Look up the RTO in the mapping table
        new_tag = rto_map.get(rto_value)

        if new_tag is None:
            audit_rows.append({
                "VM Name":        vm_name,
                "Status":         f"RTO '{rto_value}' not in mapping table",
                "Matched CI ID":  matched_ci,
                "RTO Value":      rto_value,
                "Tag Applied":    "",
                "Original Tags":  tags_val,
                "Updated Tags":   tags_val,
            })
            continue

        # Append the new tag
        new_tags = append_tag(tags_val, new_tag)
        updated_tags.at[i] = new_tags

        audit_rows.append({
            "VM Name":        vm_name,
            "Status":         "Tag added",
            "Matched CI ID":  matched_ci,
            "RTO Value":      rto_value,
            "Tag Applied":    new_tag,
            "Original Tags":  tags_val,
            "Updated Tags":   new_tags,
        })

    # ── Write updated inventory ───────────────────────────────────────────────
    inv[args.inv_tag_col] = updated_tags
    inv.to_excel(args.output, index=False)
    print(f"✓ Updated inventory written to: {args.output}")

    # ── Write audit log ───────────────────────────────────────────────────────
    audit_df = pd.DataFrame(audit_rows)

    status_order = ["Tag added", "Already tagged", "No CI match found"]
    audit_df["_sort"] = audit_df["Status"].apply(
        lambda s: next((i for i, v in enumerate(status_order) if s.startswith(v)), 99)
    )
    audit_df = audit_df.sort_values("_sort").drop(columns="_sort")

    with pd.ExcelWriter(args.audit, engine="openpyxl") as writer:
        audit_df.to_excel(writer, sheet_name="Audit Log", index=False)

        # Summary sheet
        summary = audit_df["Status"].value_counts().reset_index()
        summary.columns = ["Status", "Count"]
        summary.loc[len(summary)] = ["Run timestamp", datetime.now().strftime("%Y-%m-%d %H:%M:%S")]
        summary.to_excel(writer, sheet_name="Summary", index=False)

    print(f"✓ Audit log written to:        {args.audit}")

    # ── Print summary to console ──────────────────────────────────────────────
    counts = audit_df["Status"].value_counts()
    print("\n── Run Summary ─────────────────────────────────")
    for status, count in counts.items():
        print(f"  {status:<40} {count:>5}")
    print(f"  {'Total VMs processed':<40} {len(audit_df):>5}")
    print("────────────────────────────────────────────────")


if __name__ == "__main__":
    main()
