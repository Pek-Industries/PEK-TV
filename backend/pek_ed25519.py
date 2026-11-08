"""Ed25519 (RFC 8032) with nothing but the standard library.

Used to sign and to check PEK's official plugins (see pek_guard.py and tools/pektool.py). Verification takes a few
milliseconds; it runs once per official plugin at start-up. This is the plain reference construction, not hardened against
timing attacks, so it is meant for VERIFYING (public data) and for SIGNING on a maintainer's own machine, never for a server
that signs for strangers.
"""
import hashlib

_P = 2 ** 255 - 19
_L = 2 ** 252 + 27742317777372353535851937790883648493
_D = (-121665 * pow(121666, _P - 2, _P)) % _P
_I = pow(2, (_P - 1) // 4, _P)


def _sha512(b):
    return hashlib.sha512(b).digest()


def _inv(x):
    return pow(x, _P - 2, _P)


def _recover_x(y, sign):
    if y >= _P:
        return None
    x2 = (y * y - 1) * _inv(_D * y * y + 1) % _P
    if x2 == 0:
        return None if sign else 0
    x = pow(x2, (_P + 3) // 8, _P)
    if (x * x - x2) % _P != 0:
        x = x * _I % _P
    if (x * x - x2) % _P != 0:
        return None
    if (x & 1) != sign:
        x = _P - x
    return x


_GY = 4 * _inv(5) % _P
_GX = _recover_x(_GY, 0)
_G = (_GX, _GY, 1, _GX * _GY % _P)
_ZERO = (0, 1, 1, 0)


def _add(p, q):
    a = (p[1] - p[0]) * (q[1] - q[0]) % _P
    b = (p[1] + p[0]) * (q[1] + q[0]) % _P
    c = 2 * p[3] * q[3] * _D % _P
    d = 2 * p[2] * q[2] % _P
    e, f, g, h = b - a, d - c, d + c, b + a
    return (e * f % _P, g * h % _P, f * g % _P, e * h % _P)


def _mul(s, p):
    q = _ZERO
    while s > 0:
        if s & 1:
            q = _add(q, p)
        p = _add(p, p)
        s >>= 1
    return q


def _equal(p, q):
    if (p[0] * q[2] - q[0] * p[2]) % _P != 0:
        return False
    return (p[1] * q[2] - q[1] * p[2]) % _P == 0


def _compress(p):
    zi = _inv(p[2])
    x, y = p[0] * zi % _P, p[1] * zi % _P
    return int.to_bytes(y | ((x & 1) << 255), 32, "little")


def _decompress(s):
    if len(s) != 32:
        return None
    y = int.from_bytes(s, "little")
    sign = y >> 255
    y &= (1 << 255) - 1
    x = _recover_x(y, sign)
    if x is None:
        return None
    return (x, y, 1, x * y % _P)


def _secret_expand(seed):
    if len(seed) != 32:
        raise ValueError("an Ed25519 seed is 32 bytes")
    h = _sha512(seed)
    a = int.from_bytes(h[:32], "little")
    a &= (1 << 254) - 8
    a |= 1 << 254
    return a, h[32:]


def public_key(seed):
    a, _ = _secret_expand(seed)
    return _compress(_mul(a, _G))


def sign(seed, msg):
    a, prefix = _secret_expand(seed)
    pub = _compress(_mul(a, _G))
    r = int.from_bytes(_sha512(prefix + msg), "little") % _L
    rs = _compress(_mul(r, _G))
    h = int.from_bytes(_sha512(rs + pub + msg), "little") % _L
    s = (r + h * a) % _L
    return rs + int.to_bytes(s, 32, "little")


def verify(pub, msg, sig):
    """True only for a valid signature. Never raises on malformed input."""
    try:
        if len(pub) != 32 or len(sig) != 64:
            return False
        a_pt = _decompress(pub)
        r_pt = _decompress(sig[:32])
        if a_pt is None or r_pt is None:
            return False
        s = int.from_bytes(sig[32:], "little")
        if s >= _L:
            return False
        h = int.from_bytes(_sha512(sig[:32] + pub + msg), "little") % _L
        return _equal(_mul(s, _G), _add(r_pt, _mul(h, a_pt)))
    except Exception:  # noqa: BLE001
        return False
