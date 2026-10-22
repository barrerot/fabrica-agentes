#!/usr/bin/env python3
# Regenera el fragmento de la tabla de pozos del dashboard desde ledger/cuentas.json (fuente de verdad)
# + lectura VIVA de cuota (TAL-2672): reemplaza el scraping /usage (frágil, causó el incidente del
# dato inventado) por scripts/lector_cuotas.py (endpoints OAuth verificados, read-only, sin rotación).
import html, json, os, datetime, re, sys

BASE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BASE)
import lector_cuotas  # noqa: E402

LEDGER_PATH = os.path.join(os.path.dirname(BASE), "ledger", "cuentas.json")

# La torre corre en el host coordinador; SOLO tiene una cred local por proveedor. Esa cred NO se
# puede ligar honestamente a un pozo-contenedor concreto (audit M4) -- se usa SOLO para el bloque
# "estación" (self-contained por proveedor), nunca reutilizada en las filas de pozo.
HOST_CLAUDE_CRED = os.path.expanduser("~/.claude/.credentials.json")
HOST_CODEX_CRED = os.path.expanduser("~/.codex/auth.json")


def pct(v):
    if v is None:
        return '<span style="color:var(--faint)">—</span>'
    col = 'var(--good)' if v >= 50 else ('var(--amber)' if v >= 20 else 'var(--bad)')
    return f'<span style="color:{col}">{v}%</span>'


def cdmx(iso):
    if not iso:
        return None
    try:
        t = datetime.datetime.fromisoformat(iso.replace("Z", "+00:00"))
        loc = t.astimezone(datetime.timezone(datetime.timedelta(hours=-6)))
        return loc.strftime('%a %d, %H:%M'), iso
    except Exception:
        return iso, iso


def _remaining(used_pct):
    # Conversión USADO->RESTANTE UNA SOLA VEZ, en el borde de render (nunca en el lector, que
    # reporta % usado honesto). used_pct ya viene validado 0-100 por el lector; el round/clamp
    # de aquí es red de seguridad adicional, no la validación primaria.
    if used_pct is None:
        return None
    try:
        u = round(float(used_pct))
    except (TypeError, ValueError):
        return None
    if u < 0 or u > 100:
        return None
    return 100 - u


def _dash():
    return '<span style="color:var(--faint)">—</span>'


def _fuente_badge(source):
    # data-source = token de máquina (enum del lector); texto humano solo dice "live" o "—"
    # honesto -- nunca se inventa un número ni una etiqueta que sugiera dato real donde no lo hay.
    source = source or "unavailable"
    display = "live" if source == "live" else "—"
    return (f'<span class="fuente" data-source="{html.escape(source)}" '
            f'style="font-size:9px;color:var(--faint)"> · {html.escape(display)}</span>')


def _reset_cell(iso):
    c = cdmx(iso)
    if not c:
        return _dash()
    disp, raw = c
    return f'<span class="num" data-reset="{html.escape(raw)}">{html.escape(disp)}</span>'


def _estacion_row(provider_name, cred_path, read_fn):
    """Sub-fila SELF-CONTAINED de un proveedor del host (audit M2): nunca mezcla campos
    entre proveedores -- cada llamada renderiza SOLO lo que SU proveedor devolvió."""
    reading = read_fn(provider_name, cred_path) or {}
    source = reading.get("source", "unavailable")
    tier = reading.get("tier")
    account = reading.get("account")
    session = reading.get("session") or {}
    weekly = reading.get("weekly") or {}

    if source == "live":
        estado_txt, estcol = "LIVE", 'var(--good)'
        r5 = _remaining(session.get("used_pct"))
        r7 = _remaining(weekly.get("used_pct"))
        c5 = _reset_cell(session.get("resets_at"))
        c7 = _reset_cell(weekly.get("resets_at"))
    else:
        estado_txt, estcol = "SIN DATO", 'var(--faint)'
        r5 = r7 = None
        c5 = c7 = _dash()

    cuenta_txt = html.escape(str(account)) if account else "—"
    if tier:
        cuenta_txt += f' · {html.escape(str(tier))}'

    return f'''<tr style="border-bottom:1px solid var(--line);">
      <td style="padding:8px 8px 8px 0;" class="num"><b>estación·{html.escape(provider_name)}</b></td>
      <td style="padding:8px 8px 8px 0;">{cuenta_txt}</td>
      <td style="padding:8px 8px 8px 0;"><span style="color:{estcol}; font-weight:600; font-size:11px;">{estado_txt}</span>{_fuente_badge(source)}</td>
      <td style="padding:8px 8px 8px 0; text-align:right;" class="num">{pct(r5)}</td><td style="padding:8px 8px 8px 0;">{c5}</td>
      <td style="padding:8px 8px 8px 0; text-align:right;" class="num">{pct(r7)}</td><td style="padding:8px 8px 8px 0;">{c7}</td>
      <td style="padding:8px 8px 8px 0; text-align:right;" class="num">{_dash()}</td>
      <td style="padding:8px 0; text-align:center;"><input type="checkbox" disabled title="fila de diagnóstico (estación del host) — N/A" style="accent-color:var(--good); width:15px; height:15px;"></td>
    </tr>'''


def _pozo_key(k):
    m = re.match(r"^p(\d+)$", k)
    return (0, int(m.group(1))) if m else (1, k)


def _pozo_row(pz, info):
    alias = info.get("cuenta")
    est = info.get("estado", "?")
    estcol = ('var(--good)' if 'CARGADO' in est and 'agotad' not in est.lower()
              else ('var(--bad)' if 'CONSUMIDO' in est or 'agotad' in est.lower() else 'var(--amber)'))
    # [TAL-8037] Sin dominios/cuentas de casa: los fragmentos a quitar del alias vienen de TF_POZOS_ALIAS_STRIP
    # (separados por comas; vacío = el alias se muestra completo).
    short = alias or "—"
    for _frag in (f for f in os.environ.get("TF_POZOS_ALIAS_STRIP", "").split(",") if f):
        short = short.replace(_frag, "")

    # Columnas de USO (5h/7d/reset/Fable) = "—" HONESTO: la torre no puede ligar la cred del
    # host a este pozo-contenedor sin adivinar (audit M4) -- NO se llama al lector con la cred
    # del host para esta fila, y NO se cae al rest_*/reset_*_utc del ledger (scraping deprecado).
    return f'''<tr style="border-bottom:1px solid var(--line);">
      <td style="padding:8px 8px 8px 0;" class="num"><b>{html.escape(pz)}</b></td>
      <td style="padding:8px 8px 8px 0;">{html.escape(short)}</td>
      <td style="padding:8px 8px 8px 0;"><span style="color:{estcol}; font-weight:600; font-size:11px;">{html.escape(est)}</span>{_fuente_badge("unavailable")}</td>
      <td style="padding:8px 8px 8px 0; text-align:right;" class="num">{_dash()}</td><td style="padding:8px 8px 8px 0;">{_dash()}</td>
      <td style="padding:8px 8px 8px 0; text-align:right;" class="num">{_dash()}</td><td style="padding:8px 8px 8px 0;">{_dash()}</td>
      <td style="padding:8px 8px 8px 0; text-align:right;" class="num">{_dash()}</td>
      <td style="padding:8px 0; text-align:center;"><input type="checkbox" {"checked" if info.get("habilitada_fabrica", True) else ""} disabled style="accent-color:var(--good); width:15px; height:15px;"></td>
    </tr>'''


def render_rows(d, *, read_fn=lector_cuotas.read):
    rows = []

    # Bloque "estación (host actual)": UNA sub-fila POR PROVEEDOR, self-contained (audit M2) --
    # nunca se componen/mezclan cuota, reset, tier ni cuenta entre proveedores.
    rows.append(_estacion_row("claude", HOST_CLAUDE_CRED, read_fn))
    rows.append(_estacion_row("codex", HOST_CODEX_CRED, read_fn))

    # El conjunto de pozos se DERIVA de las claves de d["pozos"] (TAL-2294/M2): nunca enumerar
    # a mano — un pozo nuevo (p7, ...) aparece en el ledger y el generador lo recoge solo; entradas
    # desconocidas se preservan. Orden natural por el sufijo numérico (p2 antes de p10), pN sin número
    # al final por nombre.
    # Acceso OBLIGATORIO a d["pozos"] (no .get con default): un ledger sin la clave `pozos` es un
    # contrato corrupto y DEBE fallar ruidoso (KeyError), no vaciar el dashboard en silencio.
    for pz in sorted(d["pozos"].keys(), key=_pozo_key):
        info = d["pozos"].get(pz, {})
        rows.append(_pozo_row(pz, info))

    return "\n".join(rows)


def main():
    d = json.load(open(LEDGER_PATH))
    print(render_rows(d))
    print(f'<!-- LEDGER {d.get("actualizado", "?")} -->')


if __name__ == "__main__":
    main()
