"""Nombre de usuario: normalización y validación, funciones puras (Etapa 16,
F2). Ver CLAUDE.md, sección "Cloud sync" — charset ASCII a propósito: con
Unicode abierto un carácter cirílico visualmente idéntico a uno latino sería
otro usuario, suplantación trivial justo en la función cuyo objetivo es
encontrar a tu amigo. Defenderse de eso de verdad exige la tabla de
confusables de UTS #39 — una dependencia entera para una sección de amigos.
Restringir el charset hace que el problema no exista.
"""
from __future__ import annotations

import re
import unicodedata

_USERNAME_RE = re.compile(r"^[a-z0-9_]{3,20}$")

# Nombres que no puede reclamar nadie: rutas/roles que ya significan algo, o
# que se prestan a confusión ("me", "yo") en una función que busca una
# persona por nombre.
RESERVED_USERNAMES = frozenset(
    {
        "admin",
        "administrador",
        "heardy",
        "soporte",
        "support",
        "root",
        "me",
        "yo",
        "null",
        "undefined",
        "api",
        "system",
        "sistema",
    }
)


def normalize_username(raw: str) -> str:
    """NFKC (colapsa formas de ancho completo/compatibilidad) seguido de
    `casefold()`. No es lo mismo que `lower()`: casefold es la comparación de
    igualdad correcta para Unicode, aunque el resultado válido final (tras
    `validate_username`) va a ser puro ASCII de todas formas."""
    return unicodedata.normalize("NFKC", raw).casefold()


def validate_username(raw: str) -> tuple[bool, str]:
    """(válido, motivo). El motivo es para mostrarlo al usuario — a
    diferencia de otras validaciones de este servidor, aquí sí importa que
    sea específico: quien elige un nombre necesita saber qué está mal."""
    normalized = normalize_username(raw)
    if not _USERNAME_RE.match(normalized):
        return False, (
            "Sólo letras minúsculas (a-z), números y guion bajo, entre 3 y 20 caracteres"
        )
    if normalized in RESERVED_USERNAMES:
        return False, "Ese nombre está reservado"
    return True, ""
