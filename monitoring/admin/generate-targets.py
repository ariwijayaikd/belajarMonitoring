import os
import json
import yaml
from pathlib import Path

ROOT = Path("/data")
INV = ROOT / "inventory.yml"
OUTDIR = ROOT / "prometheus" / "targets"

def ensure_dir(path):
    path.mkdir(parents=True, exist_ok=True)

def write_json(name, data):
    (OUTDIR / name).write_text(json.dumps(data, indent=2))

def main():
    if not INV.exists():
        raise SystemExit("inventory.yml tidak ditemukan")

    ensure_dir(OUTDIR)

    inv = yaml.safe_load(INV.read_text()) or {}
    vms = inv.get("vms", [])

    node_exporter = []
    cadvisor_services = []
    cadvisor_central = []
    blackbox_http = []
    blackbox_tcp = []

    for vm in vms:
        name = vm.get("name")
        ip = vm.get("ip")
        role = vm.get("role", "service")
        meta = vm.get("meta", {})
        ports = vm.get("ports", {})
        bb = vm.get("blackbox", {})

        base_labels = {
            "vm": name,
            "role": role,
            **meta
        }

        # node exporter
        if ip and ports.get("node_exporter"):
            node_exporter.append({
                "targets": [f"{ip}:{ports['node_exporter']}"],
                "labels": base_labels
            })

        # cadvisor
        if ip and ports.get("cadvisor"):
            item = {
                "targets": [f"{ip}:{ports['cadvisor']}"],
                "labels": base_labels
            }
            if role == "central":
                cadvisor_central.append(item)
            else:
                cadvisor_services.append(item)

        # blackbox http
        for h in bb.get("http", []):
            if isinstance(h, str):
                blackbox_http.append({
                    "targets": [h],
                    "labels": base_labels
                })
            else:
                blackbox_http.append({
                    "targets": [h["url"]],
                    "labels": {**base_labels, **h.get("labels", {})}
                })

        # blackbox tcp
        for t in bb.get("tcp", []):
            if isinstance(t, str):
                blackbox_tcp.append({
                    "targets": [t],
                    "labels": base_labels
                })
            else:
                blackbox_tcp.append({
                    "targets": [t["target"]],
                    "labels": {**base_labels, **t.get("labels", {})}
                })

    write_json("node_exporter.json", node_exporter)
    write_json("cadvisor_services.json", cadvisor_services)
    write_json("cadvisor_central.json", cadvisor_central)
    write_json("blackbox_http.json", blackbox_http)
    write_json("blackbox_tcp.json", blackbox_tcp)

    print("Targets generated successfully.")

if __name__ == "__main__":
    main()