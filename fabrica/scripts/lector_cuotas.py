#!/usr/bin/env python3
"""Lector multi-proveedor de cuotas (TAL-2672). Headless, read-only, sin rotación.

Reemplaza el scraping del TUI `/usage` (frágil — causó el incidente del dato inventado,
p4 al "0%" cuando estaba al 88% semanal) por los endpoints OAuth de cuota ya verificados
(curl real, HTTP 200, read-only) por el lead: Claude `api.anthropic.com/api/oauth/usage`
y Codex `chatgpt.com/backend-api/wham/usage`.

REGLA DURA: el access-token on-disk se usa SOLO en la cabecera `Authorization` de la
request — jamás se retorna, imprime, loguea o expone de ninguna otra forma. Cualquier
fallo (fichero ausente, red, timeout, HTTP inesperado, JSON inválido, forma inesperada)
produce `source:"unavailable"` / `used_pct:null` — nunca un número inventado.

Salida normalizada (contrato TAL-2672):
    {provider, account, alive, session:{used_pct,resets_at}, weekly:{used_pct,resets_at},
     tier, source, needs_refresh, http_status, reason}

`alive` es tri-estado (true/false/null) — ver la matriz en Provider.read(): SOLO un 200
con forma autenticada validada da alive:true (= source "live"); un 200 con forma
inesperada (p.ej. página WAF) da alive:null, NO true, para no publicar una liveness falsa.

Subcomando `harvest`: DESCOPEADO a TAL-2679 (harvest en vivo vía incus exec en el pozo).
Aquí es un stub inerte que no toca la red ni invoca `incus`.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from abc import ABC, abstractmethod
from datetime import datetime, timezone

# Permite `import lector_cuotas` cuando gen-pozos-fragment.py lo importa desde scripts/.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

TIMEOUT_S = 15
BODY_CAP = 256 * 1024  # 256 KiB; excedente => unavailable (nunca se trunca en silencio)

# Bandas de clasificación de ventana Codex por limit_window_seconds.
_SESSION_WINDOW_S = 18000   # ~5h
_SESSION_BAND_S = 3600      # +/-1h
_WEEKLY_WINDOW_S = 604800   # ~7d
_WEEKLY_BAND_S = 86400      # +/-1d


def _empty_window() -> dict:
    return {"used_pct": None, "resets_at": None}


def _normalized(
    *,
    provider: str,
    account=None,
    alive=None,
    session=None,
    weekly=None,
    tier=None,
    source: str = "unavailable",
    needs_refresh: bool = False,
    http_status=None,
    reason: str = "unavailable",
) -> dict:
    return {
        "provider": provider,
        "account": account,
        "alive": alive,
        "session": session or _empty_window(),
        "weekly": weekly or _empty_window(),
        "tier": tier,
        "source": source,
        "needs_refresh": needs_refresh,
        "http_status": http_status,
        "reason": reason,
    }


def _is_finite_number(v) -> bool:
    # bool es subclase de int en Python -- se excluye EXPLÍCITAMENTE (un booleano nunca
    # es un porcentaje válido, aunque pase isinstance(v, (int, float))).
    if isinstance(v, bool):
        return False
    if not isinstance(v, (int, float)):
        return False
    return v == v and v not in (float("inf"), float("-inf"))  # descarta NaN/inf


def _valid_pct(v):
    """0..100 finito, no-bool -> int redondeado; cualquier otra cosa -> None."""
    if not _is_finite_number(v):
        return None
    if v < 0 or v > 100:
        return None
    return round(v)


def _iso_utc_canonical(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _parse_iso_tzaware(s):
    """ISO8601 string -> ISO8601 UTC canónico. Exige tz-aware; None si no parsea o es naive."""
    if not isinstance(s, str) or not s:
        return None
    try:
        dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return None
    if dt.tzinfo is None or dt.tzinfo.utcoffset(dt) is None:
        return None  # naive: no se puede canonicalizar a UTC de forma honesta -> rechazar
    return _iso_utc_canonical(dt)


def _epoch_to_iso(epoch):
    """epoch segundos (int/float, no-bool) -> ISO8601 UTC canónico; None si inválido."""
    if not _is_finite_number(epoch):
        return None
    try:
        dt = datetime.fromtimestamp(epoch, tz=timezone.utc)
    except (ValueError, OverflowError, OSError):
        return None
    return _iso_utc_canonical(dt)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Bloquea TODO redirect: un 302 podría reenviar el Bearer a otro host."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(newurl, code, "redirect bloqueado (anti Bearer-forwarding)", headers, fp)


def http_get(url: str, headers: dict) -> tuple:
    """GET endurecido -> (status:int, body:bytes|None). Sin redirects, sin gzip, timeout, cap de body.

    body es None si el cuerpo EXCEDE el cap (leído con cap+1 para DETECTAR el exceso, nunca
    truncar en silencio) -- el llamador lo mapea a reason="body_too_large", distinto de una
    forma inesperada normal. Deja propagar URLError/socket.timeout/ssl.SSLError al llamador.
    Nunca loguea ni imprime el body (puede contener texto de error del servidor).
    """
    req = urllib.request.Request(url, headers=headers, method="GET")
    opener = urllib.request.build_opener(_NoRedirect())
    try:
        with opener.open(req, timeout=TIMEOUT_S) as resp:
            body = resp.read(BODY_CAP + 1)
            if len(body) > BODY_CAP:
                return (resp.getcode(), None)
            return (resp.getcode(), body)
    except urllib.error.HTTPError as e:
        try:
            body = e.read(BODY_CAP + 1)
        except Exception:
            body = b""
        if len(body) > BODY_CAP:
            return (e.code, None)
        return (e.code, body)


class Provider(ABC):
    """Interfaz Provider: credFile -> GET endpoint -> salida normalizada."""

    name: str
    default_cred_path: str

    @abstractmethod
    def load_cred(self, cred_path: str):
        """Carga y devuelve SOLO lo necesario del fichero de credencial (nunca expone el token)."""
        raise NotImplementedError

    @abstractmethod
    def build_request(self, cred) -> tuple:
        """-> (url, headers) para la request autenticada."""
        raise NotImplementedError

    @staticmethod
    @abstractmethod
    def parse(raw: dict, cred) -> dict:
        """Función PURA: JSON ya parseado -> salida normalizada (sin red, sin fetch)."""
        raise NotImplementedError

    def read(self, cred_path: str = None, *, fetch=http_get) -> dict:
        cred_path = cred_path or self.default_cred_path
        try:
            cred = self.load_cred(cred_path)
        except (FileNotFoundError, OSError, ValueError, KeyError, json.JSONDecodeError):
            return _normalized(provider=self.name, reason="cred_missing")

        url, headers = self.build_request(cred)
        try:
            status, body = fetch(url, headers)
        except urllib.error.HTTPError as e:
            status = e.code
            body = b""
        except TimeoutError:
            return _normalized(provider=self.name, reason="timeout")
        except (urllib.error.URLError, OSError):
            # SOLO fallos de red esperados (URLError, socket.timeout, ssl.SSLError,
            # ConnectionError, gaierror -- todos subclases de OSError). Un `except Exception`
            # aquí enmascararía errores de PROGRAMACIÓN (TypeError/AttributeError/etc.) como
            # si fueran "—" honesto (audit code-gate #2) -- esos deben propagar y reventar.
            return _normalized(provider=self.name, reason="network")

        # Ramas por status QUE NO DEPENDEN del cuerpo primero (audit rec: un 401 con body
        # sobredimensionado no debe perder needs_refresh:true por el sentinel de tamaño).
        if status == 401:
            return _normalized(provider=self.name, alive=False, needs_refresh=True, http_status=401, reason="http_401")
        if status == 403:
            return _normalized(provider=self.name, http_status=403, reason="http_403")
        if status == 429:
            return _normalized(provider=self.name, http_status=429, reason="http_429")
        if 300 <= status < 400:
            return _normalized(provider=self.name, http_status=status, reason="redirect")
        if 500 <= status < 600:
            return _normalized(provider=self.name, http_status=status, reason="http_5xx")

        if status == 200:
            if body is None:
                return _normalized(provider=self.name, alive=None, http_status=200, reason="body_too_large")
            try:
                raw = json.loads(body.decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                return _normalized(provider=self.name, alive=None, http_status=200, reason="bad_shape")
            try:
                result = self.parse(raw, cred)
            except (KeyError, TypeError, ValueError):
                result = None
            if result is None:
                # 200 pero forma inesperada (incl. % ausente/booleano/fuera de rango): NO se
                # puede afirmar viva (audit ronda3-B1 + code-gate #1).
                return _normalized(provider=self.name, alive=None, http_status=200, reason="bad_shape")
            result["http_status"] = 200
            return result

        return _normalized(provider=self.name, http_status=status, reason="bad_shape")


class ClaudeProvider(Provider):
    name = "claude"
    default_cred_path = os.path.expanduser("~/.claude/.credentials.json")
    ENDPOINT = "https://api.anthropic.com/api/oauth/usage"

    def load_cred(self, cred_path: str):
        with open(cred_path, "r", encoding="utf-8") as f:
            doc = json.load(f)
        oauth = doc["claudeAiOauth"]
        token = oauth["accessToken"]
        if not isinstance(token, str) or not token:
            raise ValueError("accessToken vacío")
        return {"token": token, "tier": oauth.get("subscriptionType")}

    def build_request(self, cred):
        headers = {
            "Authorization": f"Bearer {cred['token']}",
            "Accept": "application/json",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "claude-code/2.1.0",
        }
        return self.ENDPOINT, headers

    @staticmethod
    def parse(raw: dict, cred) -> dict:
        if not isinstance(raw, dict):
            return None
        five_hour = raw.get("five_hour")
        seven_day = raw.get("seven_day")
        if not isinstance(five_hour, dict) and not isinstance(seven_day, dict):
            return None  # ni una ventana reconocible: forma inesperada

        def window(w):
            if not isinstance(w, dict):
                return _empty_window(), False
            pct = _valid_pct(w.get("utilization"))
            return {
                "used_pct": pct,
                "resets_at": _parse_iso_tzaware(w.get("resets_at")),
            }, (pct is not None)

        session_w, session_ok = window(five_hour)
        weekly_w, weekly_ok = window(seven_day)
        if not session_ok and not weekly_ok:
            # audit code-gate #1: la ventana existe pero SU PORCENTAJE es ausente/booleano/
            # no-numérico/fuera de rango -- NO se puede afirmar "live" sin al menos un
            # porcentaje REAL validado. Forma inválida => unavailable, nunca live falso.
            return None

        return _normalized(
            provider="claude",
            account=None,  # ~/.claude.json puede quedar obsoleto (ledger:3) -> no se liga (audit B1 r1)
            alive=True,
            session=session_w,
            weekly=weekly_w,
            tier=cred.get("tier"),
            source="live",
            needs_refresh=False,
            reason="ok",
        )


class CodexProvider(Provider):
    name = "codex"
    default_cred_path = os.path.expanduser("~/.codex/auth.json")
    ENDPOINT = "https://chatgpt.com/backend-api/wham/usage"

    def load_cred(self, cred_path: str):
        with open(cred_path, "r", encoding="utf-8") as f:
            doc = json.load(f)
        tokens = doc["tokens"]
        token = tokens["access_token"]
        if not isinstance(token, str) or not token:
            raise ValueError("access_token vacío")
        return {"token": token, "account_id": tokens.get("account_id")}

    def build_request(self, cred):
        headers = {
            "Authorization": f"Bearer {cred['token']}",
            "Accept": "application/json",
            "User-Agent": "CodexBar",
        }
        if cred.get("account_id"):
            headers["ChatGPT-Account-Id"] = cred["account_id"]
        return self.ENDPOINT, headers

    @staticmethod
    def parse(raw: dict, cred) -> dict:
        if not isinstance(raw, dict):
            return None
        rate_limit = raw.get("rate_limit")
        if not isinstance(rate_limit, dict):
            return None

        session_w, weekly_w = _empty_window(), _empty_window()
        found_valid_pct = False  # audit code-gate #1: NO basta con clasificar la ventana por
        # limit_window_seconds -- se exige al menos un used_percent REAL validado (número
        # 0-100, ni bool ni ausente) antes de poder afirmar "live".
        for key in ("primary_window", "secondary_window"):
            w = rate_limit.get(key)
            if not isinstance(w, dict):
                continue
            secs = w.get("limit_window_seconds")
            if not _is_finite_number(secs):
                continue
            used = _valid_pct(w.get("used_percent"))
            resets = _epoch_to_iso(w.get("reset_at"))
            slot = {"used_pct": used, "resets_at": resets}
            if abs(secs - _SESSION_WINDOW_S) <= _SESSION_BAND_S:
                session_w = slot
                if used is not None:
                    found_valid_pct = True
            elif abs(secs - _WEEKLY_WINDOW_S) <= _WEEKLY_BAND_S:
                weekly_w = slot
                if used is not None:
                    found_valid_pct = True
            # ventana desconocida: descartada deliberadamente (no se fuerza a un slot)

        if not found_valid_pct:
            return None  # ninguna ventana con un % REAL validado => forma inesperada, unavailable

        return _normalized(
            provider="codex",
            account=cred.get("account_id"),  # mismo fichero que el token -> ligado (audit B1 r1)
            alive=True,
            session=session_w,
            weekly=weekly_w,
            tier=raw.get("plan_type"),
            source="live",
            needs_refresh=False,
            reason="ok",
        )


class GrokProvider(Provider):
    """FASE 2 (stub documentado): endpoint protobuf verificado vivo pero no decodificado.

    POST https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig
    Bearer de ~/.grok/auth.json campo `.<scope>.key`. Responde HTTP 200 AUTORIZADO pero
    `application/grpc-web+proto` -- requiere decodificar gRPC-web o el RPC del CLI `grok`.
    No implementado aquí; source siempre "stub" (nunca number inventado).
    """

    name = "grok"
    default_cred_path = os.path.expanduser("~/.grok/auth.json")

    def load_cred(self, cred_path: str):
        raise NotImplementedError("GrokProvider: fase 2 (protobuf), ver issue")

    def build_request(self, cred):
        raise NotImplementedError("GrokProvider: fase 2 (protobuf), ver issue")

    @staticmethod
    def parse(raw: dict, cred) -> dict:
        raise NotImplementedError("GrokProvider: fase 2 (protobuf), ver issue")

    def read(self, cred_path: str = None, *, fetch=http_get) -> dict:
        return _normalized(provider="grok", source="stub", reason="stub")


class GeminiProvider(Provider):
    """FUTURO: interfaz lista, no funcional. Sin auth verificada en la máquina.

    Endpoint de investigación: cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota
    (mapeo fino no extraído). No implementado.
    """

    name = "gemini"
    default_cred_path = os.path.expanduser("~/.gemini/oauth_creds.json")

    def load_cred(self, cred_path: str):
        raise NotImplementedError("GeminiProvider: futuro, interfaz sin implementar")

    def build_request(self, cred):
        raise NotImplementedError("GeminiProvider: futuro, interfaz sin implementar")

    @staticmethod
    def parse(raw: dict, cred) -> dict:
        raise NotImplementedError("GeminiProvider: futuro, interfaz sin implementar")

    def read(self, cred_path: str = None, *, fetch=http_get) -> dict:
        return _normalized(provider="gemini", source="stub", reason="stub")


PROVIDERS = {
    "claude": ClaudeProvider,
    "codex": CodexProvider,
    "grok": GrokProvider,
    "gemini": GeminiProvider,
}


def read(provider_name: str, cred_path: str = None, *, fetch=http_get) -> dict:
    """Seam de conveniencia (usado como default read_fn por gen-pozos-fragment.py y en tests)."""
    cls = PROVIDERS.get(provider_name)
    if cls is None:
        return _normalized(provider=provider_name, reason="unknown_provider")
    return cls().read(cred_path, fetch=fetch)


def _infer_provider_from_cred_path(cred_path: str):
    base = os.path.basename(cred_path)
    if base == ".credentials.json":
        return "claude"
    if base == "auth.json":
        return "codex"
    return None


def _cmd_read(args) -> int:
    provider_name = args.provider or args.provider_pos
    cred_path = args.cred
    if not provider_name and cred_path:
        provider_name = _infer_provider_from_cred_path(cred_path)
    if not provider_name:
        print("[lector_cuotas] read: no se pudo resolver el proveedor (usa <provider>, --provider o --cred con nombre reconocible)", file=sys.stderr)
        return 2
    if provider_name not in PROVIDERS:
        print(f"[lector_cuotas] read: proveedor desconocido '{provider_name}'", file=sys.stderr)
        return 2
    result = read(provider_name, cred_path)
    print(json.dumps(result, ensure_ascii=False))
    return 0


def _cmd_harvest(args) -> int:
    # DESCOPEADO A TAL-2679: stub inerte. NO invoca incus/red; solo documenta el follow-up.
    print(
        "harvest: ver TAL-2679 (requiere comparación anti-token DENTRO de p1, devuelve solo status)",
        file=sys.stderr,
    )
    return 2


def build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="lector_cuotas.py")
    sub = p.add_subparsers(dest="cmd")

    p_read = sub.add_parser("read", help="lee la cuota de un proveedor (JSON normalizado, sin token)")
    p_read.add_argument("provider_pos", nargs="?", default=None, metavar="provider")
    p_read.add_argument("--provider", default=None)
    p_read.add_argument("--cred", default=None)
    p_read.add_argument("--json", action="store_true")  # no-op (la salida siempre es JSON); flag por compat CLI
    p_read.set_defaults(func=_cmd_read)

    p_harvest = sub.add_parser("harvest", help="[stub inerte -> TAL-2679] verificacion pre-cosecha")
    p_harvest.add_argument("--pozo", required=True)
    p_harvest.add_argument("--provider", default="codex")
    p_harvest.add_argument("--json", action="store_true")
    p_harvest.set_defaults(func=_cmd_harvest)

    return p


def main(argv=None) -> int:
    parser = build_arg_parser()
    args = parser.parse_args(argv)
    if not getattr(args, "cmd", None):
        parser.print_usage(sys.stderr)
        return 2
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
