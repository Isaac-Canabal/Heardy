"""Tests de app.library_store: validación de payload (incluido el test de
privacidad — uri/filePath/artPath se rechazan) y saneamiento del historial."""
import datetime

import pytest
from pydantic import ValidationError

from app import library_store


def test_song_valido_se_acepta():
    song = library_store.LibrarySongIn(songId="abc", title="Una canción", artist="Alguien")
    assert song.songId == "abc"


@pytest.mark.parametrize("field", ["uri", "filePath", "artPath", "modifiedAt", "missing", "ignoredFromInbox"])
def test_rechaza_campos_que_sólo_significan_algo_en_el_dispositivo(field):
    """El servidor guarda un ÍNDICE, nunca nada que sólo tenga sentido en el
    dispositivo que lo produjo — ver CLAUDE.md, "Cloud sync"."""
    with pytest.raises(ValidationError):
        library_store.LibrarySongIn(
            songId="abc", title="t", artist="a", **{field: "algo"}
        )


def test_push_payload_rechaza_campo_extra_en_la_raiz():
    with pytest.raises(ValidationError):
        library_store.LibraryPushPayload(baseVersion=0, extraCampo="algo")


def test_history_payload_acepta_utc_offset_minutes():
    """Bug real: el cliente manda utcOffsetMinutes en el cuerpo de POST
    /history (no como query param), y el modelo no lo declaraba — 422
    'extra_forbidden' en cada sincronización con sesión iniciada."""
    payload = library_store.HistoryPushPayload(rows=[], utcOffsetMinutes=-300)
    assert payload.utcOffsetMinutes == -300


def test_history_payload_sigue_rechazando_otros_campos_extra():
    with pytest.raises(ValidationError):
        library_store.HistoryPushPayload(rows=[], otroCampo="algo")


def _utc(y, m, d, h=12) -> datetime.datetime:
    return datetime.datetime(y, m, d, h, tzinfo=datetime.timezone.utc)


def _row(song_id="s1", local="2026-08-24T10:00:00", utc="2026-08-24T15:00:00+00:00", seconds=120):
    return library_store.HistoryRowIn(
        songId=song_id, playedAtLocal=local, playedAtUtc=utc, playSeconds=seconds
    )


def test_sanea_fila_valida():
    result = library_store.sanitize_history_rows([_row()], now=_utc(2026, 8, 24))
    assert len(result.accepted) == 1
    assert result.skipped_invalid == 0


def test_descarta_play_seconds_negativo():
    result = library_store.sanitize_history_rows([_row(seconds=-5)], now=_utc(2026, 8, 24))
    assert result.accepted == []
    assert result.skipped_invalid == 1


def test_recorta_play_seconds_a_24h():
    result = library_store.sanitize_history_rows([_row(seconds=10**9)], now=_utc(2026, 8, 24))
    assert result.accepted[0].playSeconds == library_store.MAX_PLAY_SECONDS


def test_descarta_fecha_muy_futura():
    row = _row(utc="2030-01-01T00:00:00+00:00")
    result = library_store.sanitize_history_rows([row], now=_utc(2026, 8, 24))
    assert result.accepted == []
    assert result.skipped_invalid == 1


def test_descarta_fecha_muy_antigua():
    row = _row(utc="2000-01-01T00:00:00+00:00")
    result = library_store.sanitize_history_rows([row], now=_utc(2026, 8, 24))
    assert result.accepted == []
    assert result.skipped_invalid == 1


def test_backfill_max_days_descarta_como_too_old_no_invalid():
    row = _row(utc="2020-08-24T15:00:00+00:00")  # ~6 años atrás
    result = library_store.sanitize_history_rows([row], now=_utc(2026, 8, 24), backfill_max_days=730)
    assert result.accepted == []
    assert result.skipped_too_old == 1
    assert result.skipped_invalid == 0


def test_dedup_dentro_del_mismo_lote():
    """Evita 'cannot affect row a second time': una clave repetida en el
    mismo payload se deduplica en Python antes de tocar la base."""
    rows = [_row(), _row()]
    result = library_store.sanitize_history_rows(rows, now=_utc(2026, 8, 24))
    assert len(result.accepted) == 1
    assert result.skipped_duplicate_in_batch == 1
