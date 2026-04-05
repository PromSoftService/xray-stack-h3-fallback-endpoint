#!/usr/bin/env python3

import argparse
import json
from pathlib import Path


def parse_json_object(raw: str | None, argument_name: str) -> dict | None:
    if raw is None:
        return None

    value = raw.strip()
    if not value:
        return None

    try:
        parsed = json.loads(value)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"{argument_name} must be valid JSON: {exc}") from exc

    if not isinstance(parsed, dict):
        raise SystemExit(f"{argument_name} must be a JSON object")

    return parsed


def build_config(
    domain: str,
    uuid: str,
    path: str,
    doh: str | None,
    remark: str,
    fingerprint: str,
    xhttp_mode: str,
    xhttp_host: str | None,
    xhttp_headers: dict | None,
    xhttp_padding_bytes: str | None,
    mux_enabled: bool,
    mux_concurrency: int,
    mux_xudp_concurrency: int,
    mux_xudp_proxy_udp_443: str,
) -> dict:
    xhttp_settings: dict = {
        "path": path,
        "mode": xhttp_mode,
    }

    if xhttp_host:
        xhttp_settings["host"] = xhttp_host

    effective_headers = dict(xhttp_headers) if xhttp_headers else None
    if effective_headers is not None and "Referer" not in effective_headers:
        effective_headers["Referer"] = f"https://{domain}/"

    xhttp_extra: dict = {}
    if effective_headers:
        xhttp_extra["headers"] = effective_headers
    if xhttp_padding_bytes:
        xhttp_extra["xPaddingBytes"] = xhttp_padding_bytes
    if xhttp_extra:
        xhttp_settings["extra"] = xhttp_extra

    proxy_outbound: dict = {
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
            "xhttpSettings": xhttp_settings
        }
    }

    if mux_enabled:
        proxy_outbound["mux"] = {
            "enabled": True,
            "concurrency": mux_concurrency,
            "xudpConcurrency": mux_xudp_concurrency,
            "xudpProxyUDP443": mux_xudp_proxy_udp_443,
        }

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
            proxy_outbound,
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
        description="Generate client config for VLESS + XHTTP + TLS/H3 fallback with optional XHTTP extra and outbound mux."
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
        "--xhttp-mode",
        default="auto",
        help="XHTTP mode, for example auto",
    )
    parser.add_argument(
        "--xhttp-host",
        default=None,
        help="Optional XHTTP host value",
    )
    parser.add_argument(
        "--xhttp-headers-json",
        default=None,
        help='Optional JSON object for xhttpSettings.extra.headers, for example {"User-Agent":"Mozilla/5.0"}',
    )
    parser.add_argument(
        "--xhttp-padding-bytes",
        default=None,
        help="Optional xhttpSettings.extra.xPaddingBytes value, for example 100-800",
    )
    parser.add_argument(
        "--mux-enabled",
        action="store_true",
        help="Enable outbound mux for proxy outbound",
    )
    parser.add_argument(
        "--mux-concurrency",
        type=int,
        default=8,
        help="Mux concurrency value",
    )
    parser.add_argument(
        "--mux-xudp-concurrency",
        type=int,
        default=16,
        help="Mux xudpConcurrency value",
    )
    parser.add_argument(
        "--mux-xudp-proxy-udp-443",
        default="reject",
        help="Mux xudpProxyUDP443 value",
    )
    parser.add_argument(
        "-o",
        "--output",
        required=True,
        help="Output JSON file path",
    )

    args = parser.parse_args()

    xhttp_headers = parse_json_object(args.xhttp_headers_json, "--xhttp-headers-json")

    xhttp_host = args.xhttp_host.strip() if args.xhttp_host else None
    xhttp_padding_bytes = (
        args.xhttp_padding_bytes.strip()
        if args.xhttp_padding_bytes and args.xhttp_padding_bytes.strip()
        else None
    )

    config = build_config(
        domain=args.domain,
        uuid=args.uuid,
        path=args.path,
        doh=args.doh,
        remark=args.remark,
        fingerprint=args.fingerprint,
        xhttp_mode=args.xhttp_mode,
        xhttp_host=xhttp_host,
        xhttp_headers=xhttp_headers,
        xhttp_padding_bytes=xhttp_padding_bytes,
        mux_enabled=args.mux_enabled,
        mux_concurrency=args.mux_concurrency,
        mux_xudp_concurrency=args.mux_xudp_concurrency,
        mux_xudp_proxy_udp_443=args.mux_xudp_proxy_udp_443,
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