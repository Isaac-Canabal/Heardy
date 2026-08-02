"""Tests de app.rate_limit — RateLimiter con un reloj falso inyectado, para
no depender de tiempo real ni de sleeps."""
import pytest
from fastapi import HTTPException

from app import rate_limit as rate_limit_module
from app.rate_limit import RateLimiter, RateLimitExceeded, enforce_rate_limit


class FakeClock:
    def __init__(self, start: float = 0.0):
        self._now = start

    def __call__(self) -> float:
        return self._now

    def advance(self, seconds: float) -> None:
        self._now += seconds


async def test_desactivado_cuando_ambos_limites_son_cero():
    limiter = RateLimiter(per_key_limit=0, per_key_window_seconds=60, daily_quota=0, clock=FakeClock())
    for _ in range(50):
        await limiter.check("cualquiera")  # nunca debe lanzar


async def test_limite_por_clave_se_respeta_por_identidad():
    limiter = RateLimiter(per_key_limit=2, per_key_window_seconds=60, daily_quota=0, clock=FakeClock())
    await limiter.check("isaac")
    await limiter.check("isaac")
    with pytest.raises(RateLimitExceeded) as exc:
        await limiter.check("isaac")
    assert exc.value.scope == "per-key"
    assert exc.value.retry_after_seconds > 0


async def test_limite_por_clave_no_se_comparte_entre_identidades():
    limiter = RateLimiter(per_key_limit=1, per_key_window_seconds=60, daily_quota=0, clock=FakeClock())
    await limiter.check("isaac")
    await limiter.check("ana")  # su propia ventana, no debe lanzar


async def test_ventana_por_clave_se_libera_tras_expirar():
    clock = FakeClock()
    limiter = RateLimiter(per_key_limit=1, per_key_window_seconds=10, daily_quota=0, clock=clock)
    await limiter.check("isaac")
    with pytest.raises(RateLimitExceeded):
        await limiter.check("isaac")
    clock.advance(11)
    await limiter.check("isaac")  # ya expiró la ventana anterior


async def test_retry_after_no_supera_la_ventana_restante():
    clock = FakeClock()
    limiter = RateLimiter(per_key_limit=1, per_key_window_seconds=30, daily_quota=0, clock=clock)
    await limiter.check("isaac")
    clock.advance(20)
    with pytest.raises(RateLimitExceeded) as exc:
        await limiter.check("isaac")
    # Quedan ~10s de los 30 originales, nunca los 30 completos.
    assert 1 <= exc.value.retry_after_seconds <= 11


async def test_tope_diario_es_compartido_entre_identidades():
    limiter = RateLimiter(per_key_limit=0, per_key_window_seconds=60, daily_quota=2, clock=FakeClock())
    await limiter.check("isaac")
    await limiter.check("ana")
    with pytest.raises(RateLimitExceeded) as exc:
        await limiter.check("carlos")
    assert exc.value.scope == "global"


async def test_peticion_rechazada_no_consume_cuota():
    limiter = RateLimiter(per_key_limit=1, per_key_window_seconds=60, daily_quota=0, clock=FakeClock())
    await limiter.check("isaac")
    for _ in range(5):
        with pytest.raises(RateLimitExceeded):
            await limiter.check("isaac")
    # Sigue siendo un único hit registrado, no cinco.
    assert len(limiter._hits["isaac"]) == 1


async def test_enforce_rate_limit_devuelve_429_con_retry_after(monkeypatch):
    limiter = RateLimiter(per_key_limit=1, per_key_window_seconds=30, daily_quota=0, clock=FakeClock())
    monkeypatch.setattr(rate_limit_module, "_limiter", limiter)

    assert await enforce_rate_limit(identity="isaac") == "isaac"

    with pytest.raises(HTTPException) as exc:
        await enforce_rate_limit(identity="isaac")
    assert exc.value.status_code == 429
    # 31, no 30: _retry_after redondea hacia arriba a propósito (nunca decirle
    # al cliente que reintente un instante antes de que la ventana se libere).
    assert exc.value.headers["Retry-After"] == "31"


async def test_enforce_rate_limit_no_afecta_a_otra_identidad(monkeypatch):
    limiter = RateLimiter(per_key_limit=1, per_key_window_seconds=30, daily_quota=0, clock=FakeClock())
    monkeypatch.setattr(rate_limit_module, "_limiter", limiter)

    await enforce_rate_limit(identity="isaac")
    assert await enforce_rate_limit(identity="ana") == "ana"
