"""Keep local HTTP fixtures independent of reverse DNS on the CI runner."""
import socket

_getfqdn = socket.getfqdn


def _loopback_fqdn(name=""):
    if name in ("127.0.0.1", "::1", "localhost"):
        return "localhost"
    return _getfqdn(name)


socket.getfqdn = _loopback_fqdn
