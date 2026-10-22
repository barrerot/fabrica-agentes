#!/usr/bin/env python3
"""Tests unit del lector de cuotas (TAL-2672).

Cubre: parse() PURO por proveedor con fixtures reales (token quitado); read() con fetch
INYECTADO (URL, headers, matriz alive/source/needs_refresh completa); render_rows() REAL de
gen-pozos-fragment.py (conversión used->restante, escape HTML, columna Fable, filas de pozo
"—"); endurecimiento de http_get (redirect bloqueado, cap+1); CLI (argv exacto, stub de
harvest); y una prueba directa de que el JSON emitido NUNCA contiene el token.

Todo hermético/offline: NINGÚN test toca la red real. El smoke read-only REAL (LECTOR_SMOKE=1)
vive fuera de este arnés (ver plan / STOP-AUDIT).
"""
import importlib.util
import json
import os
import subprocess
import sys
import unittest
import unittest.mock as mock
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
FIXTURES = os.path.join(HERE, "fixtures", "lector_cuotas")
SCRIPTS = os.path.join(ROOT, "scripts")
sys.path.insert(0, SCRIPTS)

import lector_cuotas as lc  # noqa: E402


def _load_fixture(name):
    with open(os.path.join(FIXTURES, name), "r", encoding="utf-8") as f:
        return json.load(f)


def _load_gen_pozos():
    spec = importlib.util.spec_from_file_location(
        "gen_pozos_fragment", os.path.join(SCRIPTS, "gen-pozos-fragment.py")
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class FakeFetch:
    """fetch(url, headers) -> (status, body) inyectable; registra la última llamada."""

    def __init__(self, status, body_obj=None, body_bytes=None, raise_exc=None):
        self.status = status
        if body_bytes is not None:
            self.body = body_bytes
        elif body_obj is not None:
            self.body = json.dumps(body_obj).encode("utf-8")
        else:
            self.body = b""
        self.raise_exc = raise_exc
        self.calls = []

    def __call__(self, url, headers):
        self.calls.append((url, dict(headers)))
        if self.raise_exc:
            raise self.raise_exc
        return (self.status, self.body)


# ───────────────────────── parse() puro por proveedor ─────────────────────────

class ParseClaudeTests(unittest.TestCase):
    def test_happy_path_values(self):
        raw = _load_fixture("claude_happy.json")
        out = lc.ClaudeProvider.parse(raw, {"tier": "max"})
        self.assertEqual(out["source"], "live")
        self.assertEqual(out["alive"], True)
        self.assertEqual(out["session"]["used_pct"], 76)
        self.assertEqual(out["session"]["resets_at"], "2026-07-13T20:00:00Z")
        self.assertEqual(out["weekly"]["used_pct"], 90)
        self.assertEqual(out["weekly"]["resets_at"], "2026-07-14T18:00:00Z")
        self.assertEqual(out["tier"], "max")
        # NUNCA ligar la identidad Claude vía ~/.claude.json (puede quedar
        # obsoleto si solo se propaga .credentials.json) -- account debe ser null.
        self.assertIsNone(out["account"])

    def test_bad_shape_returns_none(self):
        raw = _load_fixture("claude_bad_shape.json")
        out = lc.ClaudeProvider.parse(raw, {"tier": None})
        self.assertIsNone(out)

    def test_utilization_boolean_never_yields_live(self):
        # utilization:true en AMBAS ventanas -- antes del
        # fix esto marcaba source:"live"+alive:true con used_pct:null. Debe ser unavailable.
        raw = _load_fixture("claude_utilization_bool.json")
        out = lc.ClaudeProvider.parse(raw, {"tier": "max"})
        self.assertIsNone(out)  # None -> el llamador (read()) lo traduce a alive:null/unavailable


class ParseCodexTests(unittest.TestCase):
    def test_inverted_windows_mapped_by_seconds_not_position(self):
        # primary_window es la ventana de 7D y secondary_window la de 5H -- un mapeo naive
        # "primary=5h/secondary=7d" DEBE fallar esta aserción.
        raw = _load_fixture("codex_happy_inverted_windows.json")
        out = lc.CodexProvider.parse(raw, {"account_id": "acct_123"})
        self.assertEqual(out["source"], "live")
        self.assertEqual(out["session"]["used_pct"], 45)   # secondary_window (18000s = 5h)
        self.assertEqual(out["weekly"]["used_pct"], 3)      # primary_window (604800s = 7d)
        self.assertEqual(out["account"], "acct_123")
        self.assertEqual(out["tier"], "pro")

    def test_bad_shape_returns_none(self):
        raw = _load_fixture("codex_bad_shape.json")
        out = lc.CodexProvider.parse(raw, {})
        self.assertIsNone(out)

    def test_single_window_other_is_null(self):
        raw = _load_fixture("codex_single_window.json")
        out = lc.CodexProvider.parse(raw, {})
        self.assertIsNotNone(out)
        self.assertIsNotNone(out["session"]["used_pct"])
        self.assertIsNone(out["weekly"]["used_pct"])

    def test_missing_used_percent_never_yields_live(self):
        # Ambas ventanas clasificables por
        # limit_window_seconds pero SIN used_percent -- antes del fix `found_any` solo miraba
        # la duración de la ventana y marcaba live con used_pct:null. Debe ser unavailable.
        raw = _load_fixture("codex_missing_used_percent.json")
        out = lc.CodexProvider.parse(raw, {})
        self.assertIsNone(out)

    def test_used_percent_zero_is_valid_not_missing(self):
        raw = _load_fixture("codex_used_zero.json")
        out = lc.CodexProvider.parse(raw, {})
        self.assertEqual(out["session"]["used_pct"], 0)  # 0 es un valor REAL, no "falta"

    def test_unknown_window_discarded_known_kept(self):
        raw = _load_fixture("codex_unknown_window.json")
        out = lc.CodexProvider.parse(raw, {})
        self.assertIsNotNone(out)
        self.assertIsNotNone(out["session"]["used_pct"])  # 5h clasificada
        self.assertIsNone(out["weekly"]["used_pct"])       # ventana de 3600s descartada, no forzada


# ───────────────────────── validación de tipos/rangos ─────────────────────────

class ValidationTests(unittest.TestCase):
    def test_bool_rejected_as_percentage(self):
        self.assertIsNone(lc._valid_pct(True))
        self.assertIsNone(lc._valid_pct(False))

    def test_out_of_range_rejected(self):
        self.assertIsNone(lc._valid_pct(101))
        self.assertIsNone(lc._valid_pct(-1))

    def test_zero_is_valid(self):
        self.assertEqual(lc._valid_pct(0), 0)

    def test_naive_timestamp_rejected(self):
        self.assertIsNone(lc._parse_iso_tzaware("2026-07-13T20:00:00"))  # sin tz

    def test_tzaware_timestamp_canonicalized(self):
        self.assertEqual(lc._parse_iso_tzaware("2026-07-13T20:00:00Z"), "2026-07-13T20:00:00Z")

    def test_epoch_converted_to_iso_utc(self):
        result = lc._epoch_to_iso(1752436800)
        self.assertTrue(result.endswith("Z"))
        self.assertIn("T", result)

    def test_epoch_rejects_bool(self):
        self.assertIsNone(lc._epoch_to_iso(True))


# ───────────────────────── read() con fetch inyectado ─────────────────────────

class ReadSeamTests(unittest.TestCase):
    def setUp(self):
        self.claude_cred = os.path.join(FIXTURES, "claude_cred.json")
        self.codex_cred = os.path.join(FIXTURES, "codex_cred.json")

    def test_claude_read_asserts_url_and_headers(self):
        raw = _load_fixture("claude_happy.json")
        fetch = FakeFetch(200, body_obj=raw)
        out = lc.ClaudeProvider().read(self.claude_cred, fetch=fetch)
        self.assertEqual(len(fetch.calls), 1)
        url, headers = fetch.calls[0]
        self.assertEqual(url, "https://api.anthropic.com/api/oauth/usage")
        self.assertEqual(headers["Authorization"], "Bearer FAKE-CLAUDE-TOKEN-not-real")
        self.assertEqual(headers["anthropic-beta"], "oauth-2025-04-20")
        self.assertEqual(headers["User-Agent"], "claude-code/2.1.0")
        self.assertEqual(headers["Accept"], "application/json")
        self.assertEqual(out["source"], "live")
        self.assertEqual(out["alive"], True)

    def test_codex_read_asserts_url_and_headers(self):
        raw = _load_fixture("codex_happy_inverted_windows.json")
        fetch = FakeFetch(200, body_obj=raw)
        out = lc.CodexProvider().read(self.codex_cred, fetch=fetch)
        url, headers = fetch.calls[0]
        self.assertEqual(url, "https://chatgpt.com/backend-api/wham/usage")
        self.assertEqual(headers["Authorization"], "Bearer FAKE-CODEX-TOKEN-not-real")
        self.assertEqual(headers["User-Agent"], "CodexBar")
        self.assertEqual(headers["ChatGPT-Account-Id"], "acct_123")
        self.assertEqual(out["source"], "live")

    def test_200_bad_shape_yields_alive_null_not_true(self):
        # un 200 con forma inesperada (WAF/no-auth) NUNCA da alive:true.
        fetch = FakeFetch(200, body_obj={"unexpected": "shape"})
        out = lc.ClaudeProvider().read(self.claude_cred, fetch=fetch)
        self.assertIsNone(out["alive"])
        self.assertEqual(out["source"], "unavailable")
        self.assertEqual(out["reason"], "bad_shape")

    def test_read_claude_utilization_bool_end_to_end_is_unavailable(self):
        # Reproducción vía read() (no solo parse()): un 200 con
        # utilization:true en ambas ventanas NUNCA debe salir "verde" (source:"live").
        raw = _load_fixture("claude_utilization_bool.json")
        fetch = FakeFetch(200, body_obj=raw)
        out = lc.ClaudeProvider().read(self.claude_cred, fetch=fetch)
        self.assertNotEqual(out["source"], "live")
        self.assertIsNone(out["alive"])
        self.assertIsNone(out["session"]["used_pct"])
        self.assertIsNone(out["weekly"]["used_pct"])

    def test_read_codex_missing_used_percent_end_to_end_is_unavailable(self):
        raw = _load_fixture("codex_missing_used_percent.json")
        fetch = FakeFetch(200, body_obj=raw)
        out = lc.CodexProvider().read(self.codex_cred, fetch=fetch)
        self.assertNotEqual(out["source"], "live")
        self.assertIsNone(out["alive"])
        self.assertIsNone(out["session"]["used_pct"])
        self.assertIsNone(out["weekly"]["used_pct"])

    def test_200_invalid_json_yields_alive_null(self):
        fetch = FakeFetch(200, body_bytes=b"not json{{{")
        out = lc.ClaudeProvider().read(self.claude_cred, fetch=fetch)
        self.assertIsNone(out["alive"])
        self.assertEqual(out["reason"], "bad_shape")

    def test_401_sets_needs_refresh_and_alive_false(self):
        fetch = FakeFetch(401, body_bytes=b"")
        out = lc.ClaudeProvider().read(self.claude_cred, fetch=fetch)
        self.assertEqual(out["alive"], False)
        self.assertEqual(out["needs_refresh"], True)
        self.assertEqual(out["source"], "unavailable")
        self.assertEqual(out["http_status"], 401)

    def test_403_alive_null(self):
        fetch = FakeFetch(403, body_bytes=b"")
        out = lc.ClaudeProvider().read(self.claude_cred, fetch=fetch)
        self.assertIsNone(out["alive"])
        self.assertEqual(out["reason"], "http_403")

    def test_429_alive_null(self):
        fetch = FakeFetch(429, body_bytes=b"")
        out = lc.ClaudeProvider().read(self.claude_cred, fetch=fetch)
        self.assertIsNone(out["alive"])
        self.assertEqual(out["reason"], "http_429")

    def test_5xx_alive_null(self):
        fetch = FakeFetch(503, body_bytes=b"")
        out = lc.ClaudeProvider().read(self.claude_cred, fetch=fetch)
        self.assertIsNone(out["alive"])
        self.assertEqual(out["reason"], "http_5xx")

    def test_network_error_alive_null(self):
        fetch = FakeFetch(0, raise_exc=urllib.error.URLError("boom"))
        out = lc.ClaudeProvider().read(self.claude_cred, fetch=fetch)
        self.assertIsNone(out["alive"])
        self.assertEqual(out["reason"], "network")

    def test_timeout_alive_null(self):
        fetch = FakeFetch(0, raise_exc=TimeoutError("timed out"))
        out = lc.ClaudeProvider().read(self.claude_cred, fetch=fetch)
        self.assertIsNone(out["alive"])
        self.assertEqual(out["reason"], "timeout")

    def test_missing_cred_file_alive_null(self):
        out = lc.ClaudeProvider().read("/nonexistent/path.json", fetch=FakeFetch(200))
        self.assertIsNone(out["alive"])
        self.assertEqual(out["reason"], "cred_missing")

    def test_body_too_large_detected(self):
        def fetch(url, headers):
            return (200, None)  # sentinel de exceso (ver http_get: cap+1)

        out = lc.ClaudeProvider().read(self.claude_cred, fetch=fetch)
        self.assertEqual(out["reason"], "body_too_large")
        self.assertIsNone(out["alive"])

    def test_401_takes_priority_over_oversized_body(self):
        # audit rec (no bloqueante): un 401 con body > cap NO debe perder needs_refresh:true
        # por el sentinel de tamaño -- las ramas de status que no dependen del cuerpo se
        # evalúan ANTES de mirar si el body es demasiado grande.
        def fetch(url, headers):
            return (401, None)  # None = sentinel de exceso de http_get

        out = lc.ClaudeProvider().read(self.claude_cred, fetch=fetch)
        self.assertEqual(out["http_status"], 401)
        self.assertEqual(out["needs_refresh"], True)
        self.assertEqual(out["alive"], False)
        self.assertEqual(out["reason"], "http_401")

    def test_programming_error_in_fetch_propagates_not_swallowed(self):
        # `except Exception` en la ruta del fetch enmascaraba errores de
        # PROGRAMACIÓN como "—" silencioso. Un TypeError (no es un fallo de red) debe PROPAGAR,
        # no traducirse a reason:"network".
        def broken_fetch(url, headers):
            raise TypeError("bug de programación, no un fallo de red")

        with self.assertRaises(TypeError):
            lc.ClaudeProvider().read(self.claude_cred, fetch=broken_fetch)

    def test_key_error_in_fetch_propagates_not_swallowed(self):
        def broken_fetch(url, headers):
            raise KeyError("otro bug de programación")

        with self.assertRaises(KeyError):
            lc.ClaudeProvider().read(self.claude_cred, fetch=broken_fetch)

    def test_json_dumps_of_reading_never_contains_token(self):
        raw = _load_fixture("claude_happy.json")
        fetch = FakeFetch(200, body_obj=raw)
        out = lc.ClaudeProvider().read(self.claude_cred, fetch=fetch)
        dumped = json.dumps(out)
        self.assertNotIn("FAKE-CLAUDE-TOKEN-not-real", dumped)


# ───────────────────────── endurecimiento de http_get ─────────────────────────

class HttpGetHardeningTests(unittest.TestCase):
    def test_redirect_handler_raises(self):
        # un 3xx real pasa por este handler antes de completar la redirección -- lanzar aquí
        # es lo que impide que urllib reenvíe el header Authorization a otro host.
        handler = lc._NoRedirect()
        req = urllib.request.Request("https://example.invalid/a")
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            handler.redirect_request(req, fp=None, code=302, msg="Found", headers={}, newurl="https://evil.invalid/b")
        self.assertEqual(ctx.exception.code, 302)

    def test_oversized_body_returns_none_sentinel(self):
        class FakeResp:
            def getcode(self):
                return 200

            def read(self, n=-1):
                return b"x" * (lc.BODY_CAP + 1)

            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

        class FakeOpener:
            def open(self, req, timeout=None):
                return FakeResp()

        with mock.patch("urllib.request.build_opener", return_value=FakeOpener()):
            status, body = lc.http_get("https://example.invalid/x", {})
        self.assertEqual(status, 200)
        self.assertIsNone(body)


# ───────────────────────── render_rows() REAL ─────────────────────────

class RenderStationTests(unittest.TestCase):
    def setUp(self):
        self.gpf = _load_gen_pozos()
        self.ledger = {
            "pozos": {"p2": {"estado": "CARGADO-en-uso", "cuenta": "gmail", "habilitada_fabrica": True}},
            "cuentas": [{"alias": "gmail", "rest_5h": 100, "rest_7d": 100}],
        }

    def _fake_read_factory(self, claude_reading, codex_reading):
        def fake(provider, cred_path):
            self.assertIn(provider, ("claude", "codex"))
            return claude_reading if provider == "claude" else codex_reading

        return fake

    def test_used_88_renders_remaining_12_in_red_bucket(self):
        # no-op-proof: un render noop (mostrar 88 crudo, o "—" cuando hay dato live) NO pasa esto.
        claude_reading = {
            "provider": "claude", "account": None, "alive": True,
            "session": {"used_pct": 88, "resets_at": "2026-07-13T20:00:00Z"},
            "weekly": {"used_pct": 10, "resets_at": "2026-07-14T18:00:00Z"},
            "tier": "max<script>", "source": "live", "needs_refresh": False,
            "http_status": 200, "reason": "ok",
        }
        codex_reading = {
            "provider": "codex", "account": None, "alive": None,
            "session": {"used_pct": None, "resets_at": None},
            "weekly": {"used_pct": None, "resets_at": None},
            "tier": None, "source": "unavailable", "needs_refresh": False,
            "http_status": None, "reason": "network",
        }
        fake = self._fake_read_factory(claude_reading, codex_reading)
        out = self.gpf.render_rows(self.ledger, read_fn=fake)

        self.assertIn("12%", out)
        self.assertIn("var(--bad)", out)  # bucket ROJO para el 12% restante (used 88 -> rem 12)
        self.assertNotIn("<script>", out)  # tier escapado, no HTML crudo
        self.assertIn("&lt;script&gt;", out)
        self.assertIn('data-reset="2026-07-13T20:00:00Z"', out)  # ISO canónico intacto
        self.assertIn('data-source="live"', out)  # FUENTE=live visible (token de máquina)

    def test_pozo_row_never_calls_lector_with_host_cred(self):
        claude_reading = {
            "provider": "claude", "account": None, "alive": True,
            "session": {"used_pct": 5, "resets_at": "2026-07-13T20:00:00Z"},
            "weekly": {"used_pct": 5, "resets_at": "2026-07-14T18:00:00Z"},
            "tier": "max", "source": "live", "needs_refresh": False,
            "http_status": 200, "reason": "ok",
        }
        calls = []

        def fake(provider, cred_path):
            calls.append((provider, cred_path))
            return claude_reading

        self.gpf.render_rows(self.ledger, read_fn=fake)
        # SOLO 2 llamadas (una por proveedor de la estación) -- el pozo p2 NUNCA llama al lector
        # (evita "cuotas falsas": la cred del host no se reutiliza por fila de pozo, identidad por cuenta).
        self.assertEqual(len(calls), 2)
        self.assertEqual({c[0] for c in calls}, {"claude", "codex"})

    def test_fable_column_regression_no_rest_fable_reference(self):
        with open(os.path.join(SCRIPTS, "gen-pozos-fragment.py"), encoding="utf-8") as f:
            src = f.read()
        self.assertNotIn("rest_fable", src)

    def test_unavailable_station_renders_sin_dato_not_stale_number(self):
        unavailable_reading = {
            "provider": "claude", "account": None, "alive": None,
            "session": {"used_pct": None, "resets_at": None},
            "weekly": {"used_pct": None, "resets_at": None},
            "tier": None, "source": "unavailable", "needs_refresh": False,
            "http_status": None, "reason": "network",
        }
        fake = self._fake_read_factory(unavailable_reading, unavailable_reading)
        out = self.gpf.render_rows(self.ledger, read_fn=fake)
        self.assertIn("SIN DATO", out)

    def test_pozo_row_columns_are_dash_not_ledger_rest_values(self):
        # el ledger trae rest_5h=100/rest_7d=100 para 'gmail' -- si el render cayera al ledger
        # (scraping deprecado), aparecería "100%"; debe salir SIEMPRE "—" para filas de pozo.
        claude_reading = {
            "provider": "claude", "account": None, "alive": True,
            "session": {"used_pct": 5, "resets_at": "2026-07-13T20:00:00Z"},
            "weekly": {"used_pct": 5, "resets_at": "2026-07-14T18:00:00Z"},
            "tier": "max", "source": "live", "needs_refresh": False,
            "http_status": 200, "reason": "ok",
        }
        fake = self._fake_read_factory(claude_reading, claude_reading)
        out = self.gpf.render_rows(self.ledger, read_fn=fake)
        self.assertNotIn("100%", out)

    def test_habilitada_fabrica_read_from_authoritative_pozo_not_cuenta(self):
        # El checkbox consultaba `c` (la cuenta), que NUNCA
        # trae habilitada_fabrica -- por eso SIEMPRE quedaba checked (default True), incluso
        # para p1 (reserva INTOCABLE, habilitada_fabrica:false en el ledger). El campo
        # AUTORITATIVO vive en `info` (el objeto pozo), no en la cuenta.
        ledger = {
            "pozos": {"p1": {"estado": "CARGADO-reserva", "cuenta": "raul.martin", "habilitada_fabrica": False}},
            "cuentas": [{"alias": "raul.martin"}],
        }
        unavailable_reading = {
            "provider": "x", "account": None, "alive": None,
            "session": {"used_pct": None, "resets_at": None},
            "weekly": {"used_pct": None, "resets_at": None},
            "tier": None, "source": "unavailable", "needs_refresh": False,
            "http_status": None, "reason": "network",
        }
        fake = self._fake_read_factory(unavailable_reading, unavailable_reading)
        out = self.gpf.render_rows(ledger, read_fn=fake)
        p1_row = out.split("<b>p1</b>")[1].split("</tr>")[0]
        self.assertNotIn("checked", p1_row)

    def test_habilitada_fabrica_true_still_renders_checked(self):
        # contraprueba: habilitada_fabrica:true SÍ debe salir checked (evita que el fix
        # anterior degenere en "nunca checked").
        ledger = {
            "pozos": {"p2": {"estado": "CARGADO-en-uso", "cuenta": "gmail", "habilitada_fabrica": True}},
            "cuentas": [{"alias": "gmail"}],
        }
        unavailable_reading = {
            "provider": "x", "account": None, "alive": None,
            "session": {"used_pct": None, "resets_at": None},
            "weekly": {"used_pct": None, "resets_at": None},
            "tier": None, "source": "unavailable", "needs_refresh": False,
            "http_status": None, "reason": "network",
        }
        fake = self._fake_read_factory(unavailable_reading, unavailable_reading)
        out = self.gpf.render_rows(ledger, read_fn=fake)
        p2_row = out.split("<b>p2</b>")[1].split("</tr>")[0]
        self.assertIn("checked", p2_row)


# ───────────────────────── harvest = stub inerte (TAL-2679) ─────────────────────────

class HarvestStubTests(unittest.TestCase):
    def test_harvest_exits_2_with_tal2679_message_no_subprocess(self):
        def fake_run(*a, **kw):
            raise AssertionError("harvest NO debe invocar subprocess en este PR (stub inerte, ver TAL-2679)")

        with mock.patch("subprocess.run", side_effect=fake_run):
            parser = lc.build_arg_parser()
            args = parser.parse_args(["harvest", "--pozo", "p1"])
            rc = args.func(args)
        self.assertEqual(rc, 2)


# ───────────────────────── CLI: argv exacto + stub inerte por subprocess ─────────────────────────

class CliArgvTests(unittest.TestCase):
    def test_read_remote_form_parses(self):
        # forma EXACTA de la invocación remota: read --provider codex --cred <abs> --json
        parser = lc.build_arg_parser()
        args = parser.parse_args(
            ["read", "--provider", "codex", "--cred", "/home/vivecoder/.codex/auth.json", "--json"]
        )
        self.assertEqual(args.cmd, "read")
        self.assertEqual(args.provider, "codex")
        self.assertEqual(args.cred, "/home/vivecoder/.codex/auth.json")

    def test_harvest_form_parses(self):
        parser = lc.build_arg_parser()
        args = parser.parse_args(["harvest", "--pozo", "p1"])
        self.assertEqual(args.cmd, "harvest")
        self.assertEqual(args.pozo, "p1")

    def test_no_subcommand_is_usage_error(self):
        self.assertEqual(lc.main([]), 2)


class CliSubprocessHarvestTests(unittest.TestCase):
    """Único test que lanza subprocess real -- el stub de harvest NO toca red ni incus, así que
    es seguro/hermético (offline) y sirve de prueba end-to-end de que nunca imprime nada sensible."""

    def test_harvest_cli_never_prints_token_and_mentions_tal2679(self):
        result = subprocess.run(
            [sys.executable, os.path.join(SCRIPTS, "lector_cuotas.py"), "harvest", "--pozo", "p1"],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 2)
        combined = result.stdout + result.stderr
        self.assertIn("TAL-2679", combined)
        self.assertNotIn("Bearer ", combined)


if __name__ == "__main__":
    unittest.main()
