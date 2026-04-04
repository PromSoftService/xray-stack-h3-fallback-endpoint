#!/usr/bin/env python3

import argparse
import json
from pathlib import Path


def build_config(
    domain: str,
    uuid: str,
    path: str,
    doh: str | None,
    remark: str,
    fingerprint: str,
) -> dict:
    config = {
        "remarks": remark,
        "log": {
            "loglevel": "warning"
        },
        "inbounds": [
            {
                "tag": "socks-in",
                "listen": "127.0.0.1",
                "port": 10808,
                "protocol": "socks",
                "settings": {
                    "udp": True
                },
                "sniffing": {
                    "enabled": True,
                    "destOverride": ["http", "tls", "quic"]
                }
            },
            {
                "tag": "http-in",
                "listen": "127.0.0.1",
                "port": 10809,
                "protocol": "http",
                "settings": {}
            }
        ],
        "outbounds": [
            {
                "tag": "proxy",
                "protocol": "vless",
                "settings": {
                    "vnext": [
                        {
                            "address": domain,
                            "port": 443,
                            "users": [
                                {
                                    "id": uuid,
                                    "encryption": "none"
                                }
                            ]
                        }
                    ]
                },
                "streamSettings": {
                    "network": "xhttp",
                    "security": "tls",
                    "tlsSettings": {
                        "serverName": domain,
                        "fingerprint": fingerprint,
                        "alpn": ["h3", "h2", "http/1.1"]
                    },
                    "xhttpSettings": {
                        "path": path,
                        "mode": "auto"
                    }
                }
            },
            {
                "tag": "direct",
                "protocol": "freedom"
            },
            {
                "tag": "block",
                "protocol": "blackhole"
            }
        ]
    }

    if doh:
        config["dns"] = {
            "servers": [
                doh,
                "localhost"
            ],
            "queryStrategy": "UseIPv4"
        }

    return config


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate client config for VLESS + XHTTP + TLS/H3 fallback with uTLS fingerprint."
    )
    parser.add_argument("domain", help="Server domain")
    parser.add_argument("uuid", help="Client UUID")
    parser.add_argument("path", help="XHTTP path")
    parser.add_argument(
        "--doh",
        default=None,
        help="Optional DoH server URL, for example https://1.1.1.1/dns-query",
    )
    parser.add_argument(
        "--remark",
        default="h3 fallback",
        help="Human-readable config remark",
    )
    parser.add_argument(
        "--fingerprint",
        default="chrome",
        help="uTLS fingerprint, for example chrome, firefox, safari",
    )
    parser.add_argument(
        "-o",
        "--output",
        required=True,
        help="Output JSON file path",
    )

    args = parser.parse_args()

    config = build_config(
        domain=args.domain,
        uuid=args.uuid,
        path=args.path,
        doh=args.doh,
        remark=args.remark,
        fingerprint=args.fingerprint,
    )

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        json.dumps(config, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    print(f"Config written to: {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())