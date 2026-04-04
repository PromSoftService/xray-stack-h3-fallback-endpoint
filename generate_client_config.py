#!/usr/bin/env python3

# py generate_client_config.py DOMAIN UUID PATH --doh https://1.1.1.1/dns-query --remark "my endpoint" -o client-config.json

import argparse
import json
from pathlib import Path


def normalize_path(path: str) -> str:
    if not path.startswith("/"):
        path = "/" + path
    if path != "/" and not path.endswith("/"):
        path += "/"
    return path


def build_config(domain: str, uuid: str, path: str, doh_url: str, remark: str | None) -> dict:
    normalized_path = normalize_path(path)

    proxy_outbound = {
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
                "fingerprint": "chrome",
                "alpn": [
                    "h3",
                    "h2"
                ]
            },
            "xhttpSettings": {
                "host": domain,
                "path": normalized_path,
                "mode": "auto",
                "extra": {
                    "headers": {
                        "Referer": f"https://{domain}/"
                    },
                    "xPaddingBytes": "64-512",
                    "noGRPCHeader": True
                }
            }
        }
    }

    return {
        "remarks": remark,
        "log": {
            "loglevel": "warning"
        },
        "dns": {
            "servers": [
                doh_url,
                "localhost"
            ]
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
                    "destOverride": [
                        "http",
                        "tls",
                        "quic"
                    ]
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
            proxy_outbound,
            {
                "tag": "direct",
                "protocol": "freedom"
            },
            {
                "tag": "block",
                "protocol": "blackhole"
            }
        ],
        "routing": {
            "domainStrategy": "AsIs",
            "rules": [
                {
                    "type": "field",
                    "ip": [
                        "geoip:private"
                    ],
                    "outboundTag": "direct"
                }
            ]
        }
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate Xray client JSON config for VLESS + XHTTP + TLS + DoH via Nginx."
    )
    parser.add_argument("domain", help="Server domain, for example: example.com")
    parser.add_argument("uuid", help="VLESS UUID")
    parser.add_argument("path", help="XHTTP path, for example: /api/v1/messages/")
    parser.add_argument(
        "--doh",
        default="https://1.1.1.1/dns-query",
        help="DNS-over-HTTPS URL (default: https://1.1.1.1/dns-query)",
    )
    parser.add_argument(
        "--remark",
        default=None,
        help="Optional profile name shown by clients that read root-level remarks",
    )
    parser.add_argument(
        "-o",
        "--output",
        default="client-config.json",
        help="Output JSON file path (default: client-config.json)",
    )

    args = parser.parse_args()

    config = build_config(
        domain=args.domain,
        uuid=args.uuid,
        path=args.path,
        doh_url=args.doh,
        remark=args.remark,
    )

    output_path = Path(args.output)
    output_path.write_text(
        json.dumps(config, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    print(f"Config written to: {output_path}")
    if args.remark:
        print(f"Remark: {args.remark}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())