#!/usr/bin/env python3
from __future__ import annotations

import ipaddress
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request


def write_output(name: str, value: str) -> None:
    output_path = os.environ.get("GITHUB_OUTPUT")
    if not output_path:
        print(f"{name}={value}")
        return

    with open(output_path, "a", encoding="utf-8") as fh:
        fh.write(f"{name}={value}\n")


def normalized_server_id(raw: str) -> str:
    return raw.strip().lstrip("#")


def hcloud_get(token: str, path: str) -> dict:
    req = urllib.request.Request(
        f"https://api.hetzner.cloud/v1/{path.lstrip('/')}",
        headers={
            "Authorization": f"Bearer {token}"
        },
    )

    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return json.load(resp)

    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        sys.stderr.write(body + "\n")
        raise SystemExit(1) from exc


def server_fields(payload: dict) -> tuple[str, str, dict]:
    server = payload.get("server") or {}

    server_id = str(server.get("id") or "")
    ip = (((server.get("public_net") or {}).get("ipv4") or {}).get("ip") or "")
    labels = server.get("labels") or {}

    if not server_id or not ip:
        sys.stderr.write(json.dumps(payload, indent=2) + "\n")
        raise SystemExit("Missing server id or IPv4 in Hetzner API response")

    return server_id, ip, labels


def resolve_by_id(token: str, server_id: str):
    return server_fields(
        hcloud_get(token, f"servers/{server_id}")
    )


def resolve_by_labels(token: str, project: str, host_name: str):
    selector = f"platforminit.project={project},platforminit.host={host_name}"

    query = urllib.parse.urlencode({
        "label_selector": selector
    })

    payload = hcloud_get(token, f"servers?{query}")
    servers = payload.get("servers") or []

    if len(servers) != 1:
        names = ", ".join(str(s.get("name")) for s in servers) or "none"

        raise SystemExit(
            f"Expected exactly one Hetzner server for labels "
            f"{selector!r}, found {len(servers)}: {names}"
        )

    return server_fields({"server": servers[0]})


def resolve_by_role(token: str, project: str, role: str):
    selector = f"platforminit.project={project},platforminit.role={role}"

    query = urllib.parse.urlencode({
        "label_selector": selector
    })

    payload = hcloud_get(token, f"servers?{query}")
    servers = payload.get("servers") or []

    if len(servers) != 1:
        names = ", ".join(str(s.get("name")) for s in servers) or "none"

        raise SystemExit(
            f"Expected exactly one Hetzner server for labels "
            f"{selector!r}, found {len(servers)}: {names}"
        )

    return server_fields({"server": servers[0]})


def load_project_registry(project: str) -> dict:
    if not project:
        return {}

    cfg_path = os.path.join(
        os.getcwd(),
        "platform",
        "projects",
        f"{project}.yaml"
    )

    config = {}
    current_section = None

    try:
        with open(cfg_path, "r", encoding="utf-8") as fh:
            for raw_line in fh:
                line = raw_line.rstrip()

                if not line.strip():
                    continue

                if not line.startswith(" "):
                    current_section = line.replace(":", "").strip()
                    continue

                stripped = line.strip()

                if ":" not in stripped:
                    continue

                key, value = stripped.split(":", 1)

                config[f"{current_section}.{key.strip()}"] = (
                    value.strip().strip('"\'')
                )

    except FileNotFoundError:
        return {}

    return config


def resolve_project_token(project: str):
    cfg = load_project_registry(project)

    token_env = cfg.get("hetzner.token_secret")

    if not token_env:
        token_env = f"HCLOUD_TOKEN_{project.upper().replace('-', '_')}"

    return os.environ.get(token_env, ""), token_env


def resolve_host_name(project: str, explicit_host_name: str):
    if explicit_host_name:
        return explicit_host_name

    cfg = load_project_registry(project)

    server_prefix = cfg.get("hetzner.server_prefix")

    if server_prefix:
        return f"{server_prefix}-01"

    return f"platforminit-{project}-01"


def main():
    legacy_token = os.environ.get("INFRA_API_TOKEN", "")
    default_server_id = os.environ.get("INFRA_SERVER_ID", "")
    override_server_id = os.environ.get("SERVER_ID_OVERRIDE", "")
    host_ipv4_override = os.environ.get("HOST_IPV4_OVERRIDE", "")

    project = os.environ.get(
        "PLATFORMINIT_PROJECT",
        ""
    ).strip()

    host_name = os.environ.get(
        "PLATFORMINIT_HOST_NAME",
        ""
    ).strip()

    role = os.environ.get(
        "PLATFORMINIT_ROLE",
        ""
    ).strip()

    token = ""
    token_env = ""

    if project:
        token, token_env = resolve_project_token(project)

        if token:
            sys.stderr.write(
                f"Resolved Hetzner token from project registry: "
                f"{token_env}\n"
            )

    if not token and legacy_token:
        token = legacy_token
        token_env = "INFRA_API_TOKEN"

        sys.stderr.write(
            "Using legacy INFRA_API_TOKEN fallback\n"
        )

    if not token:
        raise SystemExit(
            "Missing Hetzner token"
        )

    host_name = resolve_host_name(
        project,
        host_name
    )

    explicit_server_id = normalized_server_id(
        override_server_id
    )

    fallback_server_id = normalized_server_id(
        default_server_id
    )

    if explicit_server_id:
        server_id, public_ip, labels = resolve_by_id(
            token,
            explicit_server_id
        )
        resolution_mode = "server_id_override"

    elif project and host_name:
        server_id, public_ip, labels = resolve_by_labels(
            token,
            project,
            host_name
        )
        resolution_mode = "label_discovery_host"

    elif project and role:
        server_id, public_ip, labels = resolve_by_role(
            token,
            project,
            role
        )
        resolution_mode = "label_discovery_role"

    elif fallback_server_id:
        server_id, public_ip, labels = resolve_by_id(
            token,
            fallback_server_id
        )
        resolution_mode = "legacy_infra_server_id"

    else:
        raise SystemExit(
            "Missing server selector"
        )

    if host_ipv4_override:
        try:
            ipaddress.IPv4Address(
                host_ipv4_override
            )
        except ipaddress.AddressValueError as exc:
            raise SystemExit(
                f"Invalid host_ipv4_override: "
                f"{host_ipv4_override}"
            ) from exc

        public_ip = host_ipv4_override

    write_output("server_id", server_id)
    write_output("public_ip", public_ip)
    write_output("resolution_mode", resolution_mode)
    write_output(
        "project",
        labels.get("platforminit.project", project)
    )
    write_output(
        "host_name",
        labels.get("platforminit.host", host_name)
    )
    write_output(
        "volume_layout",
        labels.get(
            "platforminit.volume_layout",
            "single"
        )
    )
    write_output(
        "role",
        labels.get(
            "platforminit.role",
            role or "primary"
        )
    )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())