import asyncio
import ssl
import sys
from collections import deque
from typing import Deque, Optional, cast
from urllib.parse import urlparse

from aioquic.asyncio.client import connect
from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import DataReceived, H3Event, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import ProtocolNegotiated, QuicEvent


class H3Client(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self._http: Optional[H3Connection] = H3Connection(self._quic)
        self._events_by_stream: dict[int, Deque[H3Event]] = {}
        self._waiters: dict[int, asyncio.Future[Deque[H3Event]]] = {}
        self.negotiated_alpn: Optional[str] = None

    def quic_event_received(self, event: QuicEvent) -> None:
        if isinstance(event, ProtocolNegotiated):
            # Usually this becomes "h3"
            self.negotiated_alpn = self._quic.tls.alpn_negotiated

        if self._http is not None:
            for http_event in self._http.handle_event(event):
                self.http_event_received(http_event)

    def http_event_received(self, event: H3Event) -> None:
        if isinstance(event, (HeadersReceived, DataReceived)):
            stream_id = event.stream_id
            if stream_id in self._events_by_stream:
                self._events_by_stream[stream_id].append(event)
                if event.stream_ended:
                    waiter = self._waiters.pop(stream_id)
                    waiter.set_result(self._events_by_stream.pop(stream_id))

    async def get(self, url: str) -> Deque[H3Event]:
        parsed = urlparse(url)
        if parsed.scheme != "https":
            raise ValueError("Only https:// URLs are supported")

        authority = parsed.netloc
        path = parsed.path or "/"
        if parsed.query:
            path += "?" + parsed.query

        stream_id = self._quic.get_next_available_stream_id()
        waiter: asyncio.Future[Deque[H3Event]] = self._loop.create_future()
        self._events_by_stream[stream_id] = deque()
        self._waiters[stream_id] = waiter

        self._http.send_headers(
            stream_id=stream_id,
            headers=[
                (b":method", b"GET"),
                (b":scheme", b"https"),
                (b":authority", authority.encode("utf-8")),
                (b":path", path.encode("utf-8")),
                (b"user-agent", b"aioquic-h3-check"),
            ],
            end_stream=True,
        )
        self.transmit()
        return await asyncio.shield(waiter)


async def main(url: str, insecure: bool = False) -> int:
    parsed = urlparse(url)
    if parsed.scheme != "https":
        print("FAIL: URL must start with https://")
        return 2

    host = parsed.hostname
    if not host:
        print("FAIL: could not parse hostname")
        return 2

    port = parsed.port or 443

    configuration = QuicConfiguration(
        is_client=True,
        alpn_protocols=H3_ALPN,
    )

    if insecure:
        configuration.verify_mode = ssl.CERT_NONE

    try:
        async with connect(
            host,
            port,
            configuration=configuration,
            create_protocol=H3Client,
        ) as client:
            client = cast(H3Client, client)

            events = await client.get(url)

            status = None
            headers_out = []

            for event in events:
                if isinstance(event, HeadersReceived):
                    for k, v in event.headers:
                        headers_out.append((k.decode("utf-8", "replace"), v.decode("utf-8", "replace")))
                        if k == b":status":
                            status = v.decode("ascii", "replace")

            print(f"ALPN negotiated: {client.negotiated_alpn!r}")
            print(f"HTTP status: {status}")

            for k, v in headers_out:
                if k.lower() in ("alt-svc", "server", "content-type", "quic-status"):
                    print(f"{k}: {v}")

            if client.negotiated_alpn and client.negotiated_alpn.startswith("h3"):
                print("H3 OK")
                return 0

            print("H3 FAIL: connection succeeded, but negotiated ALPN is not h3")
            return 1

    except Exception as e:
        print(f"H3 FAIL: {type(e).__name__}: {e}")
        return 1


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python check_h3.py https://your-domain")
        sys.exit(2)

    url = sys.argv[1]
    insecure = "--insecure" in sys.argv[2:]
    raise SystemExit(asyncio.run(main(url, insecure=insecure)))
