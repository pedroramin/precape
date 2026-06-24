from __future__ import annotations

import hashlib
import os
import re
import shutil
import time
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import quote

import fitz
import pandas as pd
import requests
from bs4 import BeautifulSoup

from .db import EXPORT_DIR, UPLOAD_DIR, get_conn

PROC_RE = re.compile(r"\d{7}-\d{2}\.\d{4}\.8\.26\.\d{4}")
DEPRE_RE = re.compile(r"\d{7}-\d{2}\.\d{4}\.8\.26\.0500")

@dataclass
class ExtractedFile:
    original_path: Path
    pdf_path: Path
    original_name: str
    codigo_arquivo: str | None
    hash_pdf: str


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def save_upload(upload_file) -> ExtractedFile:
    ts = time.strftime("%Y%m%d_%H%M%S")
    safe_name = re.sub(r"[^A-Za-z0-9_.-]+", "_", upload_file.filename or "lista")
    dest = UPLOAD_DIR / f"{ts}_{safe_name}"
    with dest.open("wb") as f:
        shutil.copyfileobj(upload_file.file, f)

    pdf_path = dest
    if dest.suffix.lower() == ".zip":
        extract_dir = UPLOAD_DIR / f"{ts}_{dest.stem}_extraido"
        extract_dir.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(dest, "r") as zf:
            zf.extractall(extract_dir)
        pdfs = sorted(extract_dir.glob("*.pdf"))
        if not pdfs:
            raise ValueError("O ZIP enviado não contém PDF.")
        pdf_path = pdfs[0]
    elif dest.suffix.lower() != ".pdf":
        raise ValueError("Envie um arquivo ZIP ou PDF do TJSP.")

    codigo = None
    m = re.search(r"_(\d+)\.(?:zip|pdf)$", safe_name, re.I)
    if m:
        codigo = m.group(1)
    else:
        m = re.search(r"_(\d+)\.pdf$", pdf_path.name, re.I)
        if m:
            codigo = m.group(1)

    return ExtractedFile(dest, pdf_path, safe_name, codigo, sha256_file(pdf_path))




def extracted_from_local_file(path: Path) -> ExtractedFile:
    """Prepara um arquivo já salvo localmente para reuso no parser.

    Usado principalmente quando o Playwright captura um download do TJSP.
    """
    path = Path(path)
    pdf_path = path
    if path.suffix.lower() == ".zip":
        extract_dir = path.parent / f"{path.stem}_extraido"
        extract_dir.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(path, "r") as zf:
            zf.extractall(extract_dir)
        pdfs = sorted(extract_dir.glob("*.pdf"))
        if not pdfs:
            raise ValueError("O ZIP baixado não contém PDF.")
        pdf_path = pdfs[0]
    elif path.suffix.lower() != ".pdf":
        raise ValueError("O arquivo baixado não é ZIP nem PDF.")

    codigo = None
    m = re.search(r"_(\d+)\.(?:zip|pdf)$", path.name, re.I)
    if m:
        codigo = m.group(1)
    return ExtractedFile(path, pdf_path, path.name, codigo, sha256_file(pdf_path))

def pdf_text(pdf_path: Path) -> str:
    doc = fitz.open(pdf_path)
    return "\n".join(page.get_text("text") for page in doc)


def clean(v: str | None) -> str:
    if not v:
        return ""
    return re.sub(r"\s+", " ", v).strip()


def extract_precatorios(pdf_path: Path) -> list[dict[str, Any]]:
    text = pdf_text(pdf_path)
    lines = [clean(x) for x in text.splitlines() if clean(x)]
    records: list[dict[str, Any]] = []
    # A lista vem em blocos que começam pelo Nº de autos (processo origem), seguido da natureza.
    for i, line in enumerate(lines):
        if not PROC_RE.fullmatch(line):
            continue
        if line.endswith(".0500"):
            # geralmente é DEPRE, não autos de origem
            continue
        window = lines[i:i+22]
        depre = next((x for x in window if DEPRE_RE.fullmatch(x)), "")
        if not depre:
            continue
        natureza = window[1] if len(window) > 1 else ""
        ordem_pagamento = ""
        ordem_orcamentaria = ""
        suspenso = ""
        data_protocolo = ""
        advogado = ""
        devedora = ""
        # Campos no PDF ficam bem posicionados, mas podem variar. Usamos heurísticas simples.
        for j, w in enumerate(window):
            if w == "Ordem Orçamentária:" and j+1 < len(window):
                ordem_pagamento = window[j+1]
            if re.match(r"^\d+\/\d{4}$", w) or w.startswith("ES/EP:"):
                ordem_orcamentaria = w
            if w.startswith("Suspenso?"):
                suspenso = w.replace("Suspenso?", "").strip()
                if not suspenso and j+1 < len(window):
                    suspenso = window[j+1]
            if w.startswith("Advogado(s):"):
                advogado = w.replace("Advogado(s):", "").strip()
            if w == "Devedora:" and j+1 < len(window):
                devedora = window[j+1]
            if w == "Data do Protocolo:" and j+1 < len(window):
                data_protocolo = window[j+1]
        records.append({
            "ordem_pagamento": ordem_pagamento,
            "processo_depre": depre,
            "processo_origem": line,
            "ordem_orcamentaria": ordem_orcamentaria,
            "natureza": natureza,
            "suspenso": suspenso,
            "data_protocolo": data_protocolo,
            "advogado_pdf": advogado,
            "devedora": devedora,
        })
    # remove duplicatas exatas mantendo ordem
    seen = set(); out=[]
    for r in records:
        key=(r["processo_depre"], r["processo_origem"], r.get("ordem_pagamento"))
        if key not in seen:
            seen.add(key); out.append(r)
    return out


def import_list(extracted: ExtractedFile) -> int:
    registros = extract_precatorios(extracted.pdf_path)
    conn = get_conn(); cur = conn.cursor()
    previous = cur.execute("SELECT id FROM listas ORDER BY id DESC LIMIT 1").fetchone()
    prev_keys: set[tuple[str, str]] = set()
    if previous:
        prev_rows = cur.execute("SELECT processo_depre, processo_origem FROM precatorios WHERE lista_id=?", (previous["id"],)).fetchall()
        prev_keys = {(r["processo_depre"], r["processo_origem"]) for r in prev_rows}
    current_keys = {(r["processo_depre"], r["processo_origem"]) for r in registros}
    novos_keys = current_keys - prev_keys if previous else current_keys
    removidos_keys = prev_keys - current_keys if previous else set()
    mantidos_keys = current_keys & prev_keys if previous else set()
    cur.execute(
        "INSERT INTO listas (nome_arquivo, arquivo_path, pdf_path, codigo_arquivo, hash_pdf, total_registros, novos_count, removidos_count, mantidos_count) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (extracted.original_name, str(extracted.original_path), str(extracted.pdf_path), extracted.codigo_arquivo, extracted.hash_pdf, len(registros), len(novos_keys), len(removidos_keys), len(mantidos_keys)),
    )
    lista_id = cur.lastrowid
    for r in registros:
        key = (r["processo_depre"], r["processo_origem"])
        status = "novo" if key in novos_keys else "mantido"
        cur.execute(
            """INSERT OR IGNORE INTO precatorios
               (lista_id, status_comparacao, ordem_pagamento, processo_depre, processo_origem, ordem_orcamentaria, natureza, suspenso, data_protocolo, advogado_pdf, devedora)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (lista_id, status, r["ordem_pagamento"], r["processo_depre"], r["processo_origem"], r["ordem_orcamentaria"], r["natureza"], r["suspenso"], r["data_protocolo"], r["advogado_pdf"], r["devedora"]),
        )
    # Salva removidos como linhas sintéticas para exportação? Não precisa no MVP; a contagem já fica.
    conn.commit(); conn.close()
    return lista_id


def foro_from_proc(proc: str) -> str:
    """Retorna o foro final do número CNJ, sem zeros à esquerda."""
    try:
        return str(int(proc.split(".")[-1]))
    except Exception:
        return ""


def numero_digito_ano(proc: str) -> str:
    """Ex.: 0029530-93.2017.8.26.0506 -> 0029530-93.2017"""
    m = re.match(r"^(\d{7}-\d{2}\.\d{4})", proc or "")
    return m.group(1) if m else ""


def normalize_party_name(text: str) -> str:
    text = clean(text)
    text = re.split(r"\bAdvogad[oa]\b|\bAdv\.\b|\bOAB\b|\bReqdo\b|\bRequerid[oa]\b|\bExecutad[oa]\b|\bFazenda\b", text, flags=re.I)[0]
    return clean(text.strip(" :-\n\t"))


def extract_party_from_text(partes_text: str) -> tuple[str, str]:
    """Extrai Exeqte/Reqte/Autor de um texto da área de partes do e-SAJ."""
    if not partes_text:
        return "", ""
    preferred = ["Exeqte", "Exequente", "Exequentes", "Reqte", "Requerente", "Requerentes", "Autor", "Autora", "Autores"]
    lines = [clean(x) for x in partes_text.splitlines() if clean(x)]

    for idx, line in enumerate(lines):
        for role in preferred:
            # Caso 1: linha começa com o tipo e o nome vem na mesma linha
            if re.match(rf"^{re.escape(role)}\b", line, flags=re.I):
                name = re.sub(rf"^{re.escape(role)}\b\s*:?\s*", "", line, flags=re.I)
                # Caso 2: tipo em uma linha e nome na próxima
                if not normalize_party_name(name) and idx + 1 < len(lines):
                    name = lines[idx + 1]
                name = normalize_party_name(name)
                if name and not re.match(r"^(Advogad|OAB|Reqdo|Requerid|Executad)", name, flags=re.I):
                    return name, role

    # Fallback: regex no texto bruto
    m = re.search(r"\b(Exeqte|Exequente|Reqte|Requerente|Autor|Autora)\b\s*:?\s*([^\n\r]+)", partes_text, re.I)
    if m:
        name = normalize_party_name(m.group(2))
        if name:
            return name, m.group(1)
    return "", ""


def search_esaj(processo_origem: str) -> dict[str, str]:
    """Consulta automaticamente o e-SAJ pelo Nº de autos/processo de origem.

    Importante: NÃO usar o processo DEPRE .0500. O número correto normalmente termina com o foro,
    por exemplo .0506 para Ribeirão Preto.
    """
    if not processo_origem or processo_origem.endswith(".0500"):
        return {"status": "ignorado", "observacao": "Processo inválido para e-SAJ ou número DEPRE .0500", "link_esaj": ""}

    base = "https://esaj.tjsp.jus.br/cpopg/search.do"
    ndano = numero_digito_ano(processo_origem)
    foro_full = processo_origem.split(".")[-1]
    params = {
        "conversationId": "",
        "cbPesquisa": "NUMPROC",
        "numeroDigitoAnoUnificado": ndano,
        "foroNumeroUnificado": foro_full,
        "dadosConsulta.valorConsultaNuUnificado": processo_origem,
        "dadosConsulta.valorConsulta": "",
        "dadosConsulta.tipoNuProcesso": "UNIFICADO",
    }
    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120 Safari/537.36",
        "Accept-Language": "pt-BR,pt;q=0.9,en;q=0.8",
        "Referer": "https://esaj.tjsp.jus.br/cpopg/open.do",
    }
    try:
        sess = requests.Session()
        resp = sess.get(base, params=params, headers=headers, timeout=30)
    except Exception as exc:
        return {"status": "erro", "observacao": str(exc), "link_esaj": ""}

    url = resp.url
    html = resp.text or ""
    lower = html.lower()

    # IMPORTANTE:
    # Muitas páginas válidas do e-SAJ carregam scripts/recursos com a palavra "captcha"
    # mesmo quando o processo foi aberto normalmente. Por isso NÃO podemos classificar
    # como bloqueio apenas porque a palavra aparece no HTML. Primeiro tentamos extrair
    # os dados reais do processo; só depois, se não houver dados, avaliamos bloqueio.

    if "usuário sem acesso" in lower or "usuario sem acesso" in lower:
        return {"status": "restrito", "observacao": "Usuário sem acesso ao processo", "link_esaj": url}
    if "processo não encontrado" in lower or "processo nao encontrado" in lower:
        return {"status": "nao_encontrado", "observacao": "Processo não encontrado no e-SAJ", "link_esaj": url}

    soup = BeautifulSoup(html, "html.parser")

    def text_of(selector: str) -> str:
        el = soup.select_one(selector)
        return clean(el.get_text(" ") if el else "")

    data = {
        "status": "ok",
        "observacao": "",
        "link_esaj": url,
        "classe": text_of("#classeProcesso"),
        "area": text_of("#areaProcesso"),
        "assunto": text_of("#assuntoProcesso"),
        "foro": text_of("#foroProcesso"),
        "vara": text_of("#varaProcesso"),
        "credor_nome": "",
        "tipo_participacao": "",
    }

    # Forma mais comum do e-SAJ: cada parte aparece em .nomeParteEAdvogado
    blocos = soup.select(".nomeParteEAdvogado")
    for bloco in blocos:
        txt = bloco.get_text("\n")
        nome, tipo = extract_party_from_text(txt)
        if nome:
            data["credor_nome"] = nome
            data["tipo_participacao"] = tipo
            return data

    # Fallback: tabelas de partes
    partes = soup.select_one("#tableTodasPartes") or soup.select_one("#tablePartesPrincipais")
    partes_text = partes.get_text("\n") if partes else soup.get_text("\n")
    nome, tipo = extract_party_from_text(partes_text)
    if nome:
        data["credor_nome"] = nome
        data["tipo_participacao"] = tipo
        return data

    # Só agora avaliamos se parece bloqueio/captcha de verdade.
    tem_indicio_bloqueio = (
        "não sou um robô" in lower
        or "nao sou um robo" in lower
        or "digite o texto" in lower
        or "código de segurança" in lower
        or "codigo de seguranca" in lower
        or "captcha" in lower and not (soup.select_one("#dadosProcesso") or soup.select_one("#partesDoProcesso") or soup.select_one(".nomeParteEAdvogado"))
    )
    if tem_indicio_bloqueio:
        data["status"] = "captcha/bloqueio"
        data["observacao"] = "e-SAJ aparentou solicitar captcha/bloquear a consulta automática."
        return data

    data["status"] = "sem_credor"
    data["observacao"] = "Página retornou, mas não foi possível identificar Exeqte/Reqte/Autor. Abra o link e confira se o processo exige acesso/restrição ou se o HTML veio diferente."
    return data

def consult_new_esaj(lista_id: int, only_sample: int | None = None, force: bool = False) -> int:
    conn = get_conn(); cur = conn.cursor()
    sql = """
        SELECT p.* FROM precatorios p
        LEFT JOIN consultas_esaj c ON c.precatorio_id = p.id
        WHERE p.lista_id=? AND p.status_comparacao='novo' AND p.processo_origem IS NOT NULL AND p.processo_origem NOT LIKE '%.0500'
        ORDER BY p.id ASC
    """
    if not force:
        sql = sql.replace("AND p.processo_origem IS NOT NULL", "AND c.id IS NULL AND p.processo_origem IS NOT NULL")
    rows = cur.execute(sql, (lista_id,)).fetchall()
    if only_sample:
        rows = rows[:only_sample]
    count = 0
    for r in rows:
        result = search_esaj(r["processo_origem"])
        if force:
            cur.execute("DELETE FROM consultas_esaj WHERE precatorio_id=?", (r["id"],))
        cur.execute(
            """INSERT OR REPLACE INTO consultas_esaj
               (precatorio_id, processo_origem, credor_nome, tipo_participacao, classe, area, assunto, foro, vara, link_esaj, status, observacao)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (r["id"], r["processo_origem"], result.get("credor_nome"), result.get("tipo_participacao"), result.get("classe"), result.get("area"), result.get("assunto"), result.get("foro"), result.get("vara"), result.get("link_esaj"), result.get("status", "erro"), result.get("observacao")),
        )
        conn.commit()
        count += 1
        time.sleep(1.2)
    conn.close()
    return count


def consult_demo_sample(lista_id: int, qty: int, force: bool = True) -> int:
    conn = get_conn(); cur = conn.cursor()
    rows = cur.execute("SELECT * FROM precatorios WHERE lista_id=? AND processo_origem IS NOT NULL AND processo_origem NOT LIKE '%.0500' ORDER BY id ASC LIMIT ?", (lista_id, qty)).fetchall()
    count = 0
    for r in rows:
        existing = cur.execute("SELECT id FROM consultas_esaj WHERE precatorio_id=?", (r["id"],)).fetchone()
        if existing and not force:
            continue
        result = search_esaj(r["processo_origem"])
        if force:
            cur.execute("DELETE FROM consultas_esaj WHERE precatorio_id=?", (r["id"],))
        cur.execute(
            """INSERT OR REPLACE INTO consultas_esaj
               (precatorio_id, processo_origem, credor_nome, tipo_participacao, classe, area, assunto, foro, vara, link_esaj, status, observacao)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (r["id"], r["processo_origem"], result.get("credor_nome"), result.get("tipo_participacao"), result.get("classe"), result.get("area"), result.get("assunto"), result.get("foro"), result.get("vara"), result.get("link_esaj"), result.get("status", "erro"), result.get("observacao")),
        )
        conn.commit(); count += 1; time.sleep(1.2)
    conn.close(); return count


def export_lista_excel(lista_id: int) -> Path:
    conn = get_conn()
    latest_id = values_report_id_for_lista(lista_id)
    rows = conn.execute(
        """
        SELECT p.status_comparacao, p.ordem_pagamento, p.processo_depre, p.processo_origem,
               p.ordem_orcamentaria, p.natureza, p.suspenso, p.data_protocolo, p.advogado_pdf, p.devedora,
               c.credor_nome, c.tipo_participacao, c.classe, c.area, c.assunto, c.foro, c.vara, c.link_esaj,
               c.status AS status_esaj, c.observacao AS observacao_esaj, c.created_at AS data_consulta_esaj,
               v.saldo, v.valor_pago, v.numero_ordem, v.ano_orcamentario, v.condicao_superpreferencia,
               CASE
                 WHEN v.saldo IS NULL THEN NULL
                 WHEN p.natureza LIKE 'ALIMENT%' OR v.natureza='A' THEN v.saldo * 0.60
                 ELSE v.saldo * 0.45
               END AS oferta_sugerida
        FROM precatorios p
        LEFT JOIN consultas_esaj c ON c.precatorio_id = p.id
        LEFT JOIN valores_precatorios v ON v.processo_depre=p.processo_depre AND v.relatorio_id=?
        WHERE p.lista_id=?
        ORDER BY CASE p.status_comparacao WHEN 'novo' THEN 0 ELSE 1 END, p.id
        """,
        (latest_id or -1, lista_id),
    ).fetchall()
    df = pd.DataFrame([dict(r) for r in rows])
    out = EXPORT_DIR / f"leads_precatorios_lista_{lista_id}_{time.strftime('%Y%m%d_%H%M%S')}.xlsx"
    with pd.ExcelWriter(out, engine="openpyxl") as writer:
        df.to_excel(writer, index=False, sheet_name="lista_completa")
        if not df.empty and "status_comparacao" in df.columns:
            df[df["status_comparacao"] == "novo"].to_excel(writer, index=False, sheet_name="novos")
        if not df.empty and "credor_nome" in df.columns:
            df[df["credor_nome"].fillna("") != ""].to_excel(writer, index=False, sheet_name="com_credor")
        if not df.empty and "saldo" in df.columns:
            df[df["saldo"].notna()].to_excel(writer, index=False, sheet_name="com_valor")
    conn.close()
    return out

# -----------------------------
# Módulo de valores atualizados
# -----------------------------

MONEY_RE = re.compile(r"-?\d{1,3}(?:\.\d{3})*,\d{2}")
DATE_RE = re.compile(r"\d{2}/\d{2}/\d{4}")

def br_money_to_float(value: str | None) -> float | None:
    if not value:
        return None
    value = value.replace("*", "").strip()
    try:
        return float(value.replace(".", "").replace(",", "."))
    except Exception:
        return None


def extract_saldo_atualizado_em(text: str) -> str:
    # No PDF o rótulo e a data podem estar em linhas separadas.
    lines = [clean(x) for x in text.splitlines() if clean(x)]
    for i, line in enumerate(lines):
        if "Demonstrar Saldo Atualizado em" in line:
            # tenta data na mesma linha ou nas próximas 30 linhas, pois o PDF sai em colunas.
            chunk = " ".join(lines[i:i+31])
            m = DATE_RE.search(chunk)
            if m:
                return m.group(0)
    return ""


def extract_entidade_valores(text: str) -> str:
    lines = [clean(x) for x in text.splitlines() if clean(x)]
    for line in lines[:30]:
        if "MUNICÍPIO" in line.upper() or "MUNICIPIO" in line.upper():
            return line
    return ""


def parse_value_line(line: str) -> dict[str, Any] | None:
    line = clean(line).replace("−", "-")
    m = re.match(rf"^(?P<depre>{DEPRE_RE.pattern})\s+(?P<nat>[A-Z])\s+(?P<rest>.+)$", line)
    if not m:
        return None
    monies = list(MONEY_RE.finditer(line))
    if len(monies) < 2:
        return None
    valor_pago_txt = monies[-2].group(0)
    saldo_txt = monies[-1].group(0)
    before_money = clean(line[:monies[-2].start()])

    depre = m.group("depre")
    nat = m.group("nat")
    rest = clean(m.group("rest"))

    ordem_matches = list(re.finditer(r"\b\d+\/\d{4}\b", before_money))
    numero_ordem = ordem_matches[-1].group(0) if ordem_matches else ""
    ano = numero_ordem.split("/")[-1] if "/" in numero_ordem else ""

    dates = list(DATE_RE.finditer(before_money))
    data_ensejo = dates[-1].group(0) if dates else ""
    protocolo = ""
    condicao = ""

    if numero_ordem:
        idx_ordem = before_money.rfind(numero_ordem)
        # Remove processo/natureza do início e usa o que vem antes da ordem como protocolo.
        prefix = before_money
        prefix = re.sub(rf"^{re.escape(depre)}\s+{re.escape(nat)}\s+", "", prefix).strip()
        protocolo = clean(prefix[:max(0, idx_ordem - (len(before_money) - len(prefix)))]).strip()
    if data_ensejo:
        idx_data = before_money.rfind(data_ensejo)
        condicao = clean(before_money[idx_data + len(data_ensejo):])

    return {
        "processo_depre": depre,
        "natureza": nat,
        "protocolo": protocolo,
        "numero_ordem": numero_ordem,
        "data_ensejo_ordem": data_ensejo,
        "condicao_superpreferencia": condicao,
        "valor_pago": br_money_to_float(valor_pago_txt),
        "saldo": br_money_to_float(saldo_txt),
        "ano_orcamentario": ano,
    }


def extract_valores_precatorios(pdf_path: Path) -> tuple[dict[str, str], list[dict[str, Any]]]:
    text = pdf_text(pdf_path)
    meta = {
        "saldo_atualizado_em": extract_saldo_atualizado_em(text),
        "entidade": extract_entidade_valores(text),
    }
    lines = [clean(x).replace("−", "-") for x in text.splitlines() if clean(x)]
    rows: list[dict[str, Any]] = []
    seen: set[str] = set()

    # O PDF de dívida anual sai em colunas, mas o texto extraído pelo PyMuPDF
    # vem em sequência vertical: data, natureza, valor pago, saldo, nº ordem,
    # protocolo, processo DEPRE, condição de superpreferência. Por isso a
    # extração usa o Processo DEPRE como âncora e lê os campos anteriores.
    for i, line in enumerate(lines):
        if not DEPRE_RE.fullmatch(line):
            continue
        if i < 6:
            continue
        depre = line
        if depre in seen:
            continue
        seen.add(depre)

        dt_ensejo = lines[i - 6] if DATE_RE.fullmatch(lines[i - 6]) else ""
        nat = lines[i - 5] if re.fullmatch(r"[A-Z]", lines[i - 5]) else ""
        valor_pago = br_money_to_float(lines[i - 4])
        saldo = br_money_to_float(lines[i - 3])
        numero_ordem = lines[i - 2] if re.fullmatch(r"\d+\/\d{4}", lines[i - 2]) else ""
        protocolo = lines[i - 1]
        condicao = lines[i + 1] if i + 1 < len(lines) and not lines[i + 1].startswith("Total do Ano") else ""
        ano = numero_ordem.split("/")[-1] if "/" in numero_ordem else ""

        # Validação mínima para evitar capturar lixo.
        if valor_pago is None or saldo is None:
            continue

        rows.append({
            "processo_depre": depre,
            "natureza": nat,
            "protocolo": protocolo,
            "numero_ordem": numero_ordem,
            "data_ensejo_ordem": dt_ensejo,
            "condicao_superpreferencia": condicao,
            "valor_pago": valor_pago,
            "saldo": saldo,
            "ano_orcamentario": ano,
        })
    return meta, rows

def import_values_report(extracted: ExtractedFile) -> int:
    meta, rows = extract_valores_precatorios(extracted.pdf_path)
    if not rows:
        raise ValueError("Não consegui extrair linhas de valores. Confirme se o PDF é o relatório 'Consulta do Total da Dívida Anual - Detalhado'.")
    conn = get_conn(); cur = conn.cursor()
    cur.execute(
        """INSERT INTO relatorios_valores
           (nome_arquivo, arquivo_path, pdf_path, codigo_arquivo, hash_pdf, entidade, saldo_atualizado_em, total_registros)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
        (extracted.original_name, str(extracted.original_path), str(extracted.pdf_path), extracted.codigo_arquivo,
         extracted.hash_pdf, meta.get("entidade"), meta.get("saldo_atualizado_em"), len(rows)),
    )
    relatorio_id = cur.lastrowid
    for r in rows:
        cur.execute(
            """INSERT OR IGNORE INTO valores_precatorios
               (relatorio_id, processo_depre, natureza, protocolo, numero_ordem, data_ensejo_ordem,
                condicao_superpreferencia, valor_pago, saldo, ano_orcamentario)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (relatorio_id, r["processo_depre"], r["natureza"], r["protocolo"], r["numero_ordem"],
             r["data_ensejo_ordem"], r["condicao_superpreferencia"], r["valor_pago"], r["saldo"], r["ano_orcamentario"]),
        )
    conn.commit(); conn.close()
    return relatorio_id




# Página inicial oficial de credores do TJSP, onde existe o acesso a "Valores Atualizados dos Precatórios".
# Mantemos configurável para ajuste futuro sem mexer no código:
# set TJSP_VALORES_URL=https://...
TJSP_VALORES_URL = os.getenv("TJSP_VALORES_URL", "https://www.tjsp.jus.br/Precatorios/Precatorios/Credores")


def baixar_e_vincular_valores_tjsp(lista_id: int, timeout_minutos: int = 15) -> tuple[int, str]:
    """Abre o TJSP em navegador real, espera o usuário resolver CAPTCHA e baixar o PDF de valores.

    Como o CAPTCHA precisa ser humano, o navegador fica aberto. Assim que o download ocorrer,
    o arquivo é salvo, importado como relatório de valores e vinculado à lista informada.
    """
    try:
        from playwright.sync_api import sync_playwright
    except Exception as exc:
        raise RuntimeError("Playwright não está instalado. Rode instalar_windows.bat novamente.") from exc

    ts = time.strftime("%Y%m%d_%H%M%S")
    download_dir = UPLOAD_DIR / f"{ts}_download_valores_tjsp"
    download_dir.mkdir(parents=True, exist_ok=True)

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=False)
        context = browser.new_context(accept_downloads=True)
        page = context.new_page()
        page.goto(TJSP_VALORES_URL, wait_until="domcontentloaded", timeout=60000)
        try:
            page.bring_to_front()
        except Exception:
            pass
        # O usuário navega/seleciona entidade, resolve o CAPTCHA e clica para gerar o relatório.
        with page.expect_download(timeout=timeout_minutos * 60 * 1000) as download_info:
            pass
        download = download_info.value
        suggested = download.suggested_filename or f"valores_tjsp_{ts}.pdf"
        safe_name = re.sub(r"[^A-Za-z0-9_.-]+", "_", suggested)
        dest = download_dir / safe_name
        download.save_as(dest)
        browser.close()

    extracted = extracted_from_local_file(dest)
    relatorio_id = import_values_report(extracted)
    vincular_relatorio_valores(lista_id, relatorio_id)
    return relatorio_id, dest.name

def latest_values_report_id() -> int | None:
    conn = get_conn()
    row = conn.execute("SELECT id FROM relatorios_valores ORDER BY id DESC LIMIT 1").fetchone()
    conn.close()
    return int(row["id"]) if row else None


def export_analise_excel(lista_id: int) -> Path:
    conn = get_conn()
    latest_id = values_report_id_for_lista(lista_id)
    rows = conn.execute(
        """
        SELECT p.status_comparacao, p.ordem_pagamento, p.processo_depre, p.processo_origem,
               p.natureza, p.devedora, p.advogado_pdf,
               c.credor_nome, c.tipo_participacao, c.status AS status_esaj,
               v.saldo, v.valor_pago, v.numero_ordem, v.ano_orcamentario, v.condicao_superpreferencia,
               CASE
                 WHEN v.saldo IS NULL THEN NULL
                 WHEN p.natureza LIKE 'ALIMENT%' OR v.natureza='A' THEN v.saldo * 0.60
                 ELSE v.saldo * 0.45
               END AS oferta_sugerida
        FROM precatorios p
        LEFT JOIN consultas_esaj c ON c.precatorio_id=p.id
        LEFT JOIN valores_precatorios v ON v.processo_depre=p.processo_depre AND v.relatorio_id=?
        WHERE p.lista_id=?
        ORDER BY CASE p.status_comparacao WHEN 'novo' THEN 0 ELSE 1 END, p.id
        """,
        (latest_id or -1, lista_id),
    ).fetchall()
    df = pd.DataFrame([dict(r) for r in rows])
    out = EXPORT_DIR / f"analise_comercial_lista_{lista_id}_{time.strftime('%Y%m%d_%H%M%S')}.xlsx"
    with pd.ExcelWriter(out, engine="openpyxl") as writer:
        df.to_excel(writer, index=False, sheet_name="analise_comercial")
        if "status_comparacao" in df.columns:
            df[df["status_comparacao"] == "novo"].to_excel(writer, index=False, sheet_name="novos")
        if "saldo" in df.columns:
            df[df["saldo"].notna()].to_excel(writer, index=False, sheet_name="com_valor")
    conn.close()
    return out


def values_report_id_for_lista(lista_id: int) -> int | None:
    """Retorna o relatório de valores vinculado à lista; se não houver, usa o último importado."""
    conn = get_conn()
    row = conn.execute("SELECT valores_relatorio_id FROM listas WHERE id=?", (lista_id,)).fetchone()
    if row and row["valores_relatorio_id"]:
        rid = int(row["valores_relatorio_id"])
        conn.close()
        return rid
    row = conn.execute("SELECT id FROM relatorios_valores ORDER BY id DESC LIMIT 1").fetchone()
    conn.close()
    return int(row["id"]) if row else None


def vincular_relatorio_valores(lista_id: int, relatorio_id: int) -> None:
    conn = get_conn()
    conn.execute("UPDATE listas SET valores_relatorio_id=? WHERE id=?", (relatorio_id, lista_id))
    conn.commit()
    conn.close()
