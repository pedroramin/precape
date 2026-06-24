from __future__ import annotations

from pathlib import Path
import os

from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from itsdangerous import URLSafeSerializer, BadSignature

from .db import EXPORT_DIR, get_conn, init_db, verify_password
from .services import (
    consult_demo_sample,
    consult_new_esaj,
    export_analise_excel,
    export_lista_excel,
    import_list,
    import_values_report,
    baixar_e_vincular_valores_tjsp,
    latest_values_report_id,
    save_upload,
    values_report_id_for_lista,
    vincular_relatorio_valores,
)

app = FastAPI(title="Precatórios Web MVP")
BASE_DIR = Path(__file__).resolve().parent
app.mount("/static", StaticFiles(directory=BASE_DIR / "static"), name="static")
templates = Jinja2Templates(directory=BASE_DIR / "templates")
serializer = URLSafeSerializer(os.getenv("SECRET_KEY", "troque-esta-chave-em-producao"), salt="precatorios-login")

@app.on_event("startup")
def startup():
    init_db()


def current_user(request: Request):
    token = request.cookies.get("session")
    if not token:
        return None
    try:
        data = serializer.loads(token)
    except BadSignature:
        return None
    conn = get_conn()
    user = conn.execute("SELECT id,nome,email,perfil FROM users WHERE id=? AND ativo=1", (data.get("uid"),)).fetchone()
    conn.close()
    return user


def require_user(request: Request):
    user = current_user(request)
    if not user:
        raise HTTPException(status_code=303, headers={"Location": "/login"})
    return user


def flash_redirect(url: str, message: str = "", level: str = "success"):
    resp = RedirectResponse(url, status_code=303)
    if message:
        resp.set_cookie("flash", serializer.dumps({"message": message, "level": level}), max_age=20)
    return resp


def get_flash(request: Request):
    raw = request.cookies.get("flash")
    if not raw:
        return None
    try:
        return serializer.loads(raw)
    except Exception:
        return None


def money_br(value):
    if value is None or value == "":
        return "-"
    try:
        v = float(value)
    except Exception:
        return str(value)
    txt = f"{v:,.2f}".replace(",", "X").replace(".", ",").replace("X", ".")
    return "R$ " + txt

templates.env.filters["money_br"] = money_br


def render(request: Request, name: str, context: dict):
    context.setdefault("user", current_user(request))
    context.setdefault("flash", get_flash(request))
    resp = templates.TemplateResponse(request, name, context)
    if request.cookies.get("flash"):
        resp.delete_cookie("flash")
    return resp

@app.get("/")
def home(request: Request):
    if not current_user(request):
        return RedirectResponse("/login", status_code=303)
    return RedirectResponse("/dashboard", status_code=303)

@app.get("/login")
def login_page(request: Request):
    return render(request, "login.html", {})

@app.post("/login")
def login(request: Request, email: str = Form(...), senha: str = Form(...)):
    conn = get_conn()
    user = conn.execute("SELECT * FROM users WHERE email=? AND ativo=1", (email.strip().lower(),)).fetchone()
    conn.close()
    if not user or not verify_password(senha, user["senha_hash"]):
        return render(request, "login.html", {"error": "E-mail ou senha inválidos."})
    resp = RedirectResponse("/dashboard", status_code=303)
    resp.set_cookie("session", serializer.dumps({"uid": user["id"]}), httponly=True, samesite="lax")
    return resp

@app.get("/logout")
def logout():
    resp = RedirectResponse("/login", status_code=303)
    resp.delete_cookie("session")
    return resp

@app.get("/dashboard")
def dashboard(request: Request):
    require_user(request)
    conn = get_conn()
    stats = {
        "listas": conn.execute("SELECT COUNT(*) c FROM listas").fetchone()["c"],
        "precatorios": conn.execute("SELECT COUNT(*) c FROM precatorios").fetchone()["c"],
        "novos": conn.execute("SELECT COUNT(*) c FROM precatorios WHERE status_comparacao='novo'").fetchone()["c"],
        "consultas_ok": conn.execute("SELECT COUNT(*) c FROM consultas_esaj WHERE status='ok' AND credor_nome IS NOT NULL AND credor_nome != ''").fetchone()["c"],
        "relatorios_valores": conn.execute("SELECT COUNT(*) c FROM relatorios_valores").fetchone()["c"],
        "valores_importados": conn.execute("SELECT COUNT(*) c FROM valores_precatorios").fetchone()["c"],
    }
    ultima = conn.execute("SELECT * FROM listas ORDER BY id DESC LIMIT 1").fetchone()
    ultimo_valor = conn.execute("SELECT * FROM relatorios_valores ORDER BY id DESC LIMIT 1").fetchone()
    listas = conn.execute("SELECT * FROM listas ORDER BY id DESC LIMIT 5").fetchall()
    conn.close()
    return render(request, "dashboard.html", {"stats": stats, "ultima": ultima, "ultimo_valor": ultimo_valor, "listas": listas})

@app.get("/listas")
def listas(request: Request):
    require_user(request)
    conn = get_conn()
    rows = conn.execute("SELECT * FROM listas ORDER BY id DESC").fetchall()
    conn.close()
    return render(request, "listas.html", {"listas": rows})

@app.get("/listas/upload")
def upload_page(request: Request):
    require_user(request)
    return render(request, "upload.html", {})

@app.post("/listas/upload")
def upload_lista(request: Request, arquivo: UploadFile = File(...)):
    require_user(request)
    try:
        extracted = save_upload(arquivo)
        lista_id = import_list(extracted)
    except Exception as exc:
        return render(request, "upload.html", {"error": f"Erro ao processar arquivo: {exc}"})
    return flash_redirect(f"/listas/{lista_id}", "Lista processada com sucesso.")

@app.get("/listas/{lista_id}")
def lista_detail(request: Request, lista_id: int):
    require_user(request)
    conn = get_conn()
    lista = conn.execute("SELECT * FROM listas WHERE id=?", (lista_id,)).fetchone()
    if not lista:
        conn.close(); raise HTTPException(404)
    counts = {
        "total": conn.execute("SELECT COUNT(*) c FROM precatorios WHERE lista_id=?", (lista_id,)).fetchone()["c"],
        "novos": conn.execute("SELECT COUNT(*) c FROM precatorios WHERE lista_id=? AND status_comparacao='novo'", (lista_id,)).fetchone()["c"],
        "com_credor": conn.execute("SELECT COUNT(*) c FROM precatorios p JOIN consultas_esaj c ON c.precatorio_id=p.id WHERE p.lista_id=? AND c.credor_nome IS NOT NULL AND c.credor_nome != ''", (lista_id,)).fetchone()["c"],
        "pendentes_esaj": conn.execute("SELECT COUNT(*) c FROM precatorios p LEFT JOIN consultas_esaj c ON c.precatorio_id=p.id WHERE p.lista_id=? AND p.status_comparacao='novo' AND c.id IS NULL", (lista_id,)).fetchone()["c"],
    }
    latest_val = values_report_id_for_lista(lista_id)
    rel_val = conn.execute("SELECT * FROM relatorios_valores WHERE id=?", (latest_val,)).fetchone() if latest_val else None
    novos = conn.execute("""
        SELECT p.*, c.credor_nome, c.tipo_participacao, c.status AS status_esaj, c.observacao AS observacao_esaj,
               v.saldo, v.valor_pago, v.numero_ordem, v.ano_orcamentario,
               CASE
                 WHEN v.saldo IS NULL THEN NULL
                 WHEN p.natureza LIKE 'ALIMENT%' OR v.natureza='A' THEN v.saldo * 0.60
                 ELSE v.saldo * 0.45
               END AS oferta_sugerida
        FROM precatorios p
        LEFT JOIN consultas_esaj c ON c.precatorio_id=p.id
        LEFT JOIN valores_precatorios v ON v.processo_depre=p.processo_depre AND v.relatorio_id=?
        WHERE p.lista_id=?
        ORDER BY CASE p.status_comparacao WHEN 'novo' THEN 0 ELSE 1 END, p.id ASC LIMIT 300
    """, (latest_val or -1, lista_id)).fetchall()
    conn.close()
    return render(request, "lista_detail.html", {"lista": lista, "counts": counts, "novos": novos, "latest_valores_id": latest_val, "rel_val": rel_val})

@app.post("/listas/{lista_id}/consultar-esaj")
def consultar_esaj(request: Request, lista_id: int):
    require_user(request)
    qtd = consult_new_esaj(lista_id)
    return flash_redirect(f"/listas/{lista_id}", f"Consulta e-SAJ concluída. Processos consultados: {qtd}.")

@app.post("/listas/{lista_id}/valores-upload")
def upload_valores_da_lista(request: Request, lista_id: int, arquivo: UploadFile = File(...)):
    require_user(request)
    try:
        extracted = save_upload(arquivo)
        relatorio_id = import_values_report(extracted)
        vincular_relatorio_valores(lista_id, relatorio_id)
    except Exception as exc:
        return flash_redirect(f"/listas/{lista_id}", f"Erro ao processar PDF de valores: {exc}", "error")
    return flash_redirect(f"/listas/{lista_id}", "PDF de valores vinculado à lista. A análise completa foi atualizada.")

@app.post("/listas/{lista_id}/baixar-valores-tjsp")
def baixar_valores_tjsp(request: Request, lista_id: int):
    require_user(request)
    try:
        relatorio_id, nome_arquivo = baixar_e_vincular_valores_tjsp(lista_id)
    except Exception as exc:
        return flash_redirect(f"/listas/{lista_id}", f"Erro ao baixar/importar valores do TJSP: {exc}", "error")
    return flash_redirect(f"/listas/{lista_id}", f"Valores baixados e vinculados à lista. Arquivo: {nome_arquivo}")

@app.post("/listas/{lista_id}/demo")
def demo_esaj(request: Request, lista_id: int, quantidade: int = Form(10)):
    require_user(request)
    quantidade = max(1, min(int(quantidade), 200))
    qtd = consult_demo_sample(lista_id, quantidade)
    return flash_redirect(f"/listas/{lista_id}", f"Demonstração concluída. Processos consultados: {qtd}.")

@app.get("/listas/{lista_id}/exportar")
def exportar(request: Request, lista_id: int):
    require_user(request)
    path = export_lista_excel(lista_id)
    return FileResponse(path, filename=path.name, media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")

@app.get("/listas/{lista_id}/exportar-analise")
def exportar_analise(request: Request, lista_id: int):
    require_user(request)
    path = export_analise_excel(lista_id)
    return FileResponse(path, filename=path.name, media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")

@app.get("/valores")
def valores(request: Request):
    require_user(request)
    conn = get_conn()
    rows = conn.execute("SELECT * FROM relatorios_valores ORDER BY id DESC").fetchall()
    conn.close()
    return render(request, "valores.html", {"relatorios": rows})

@app.get("/valores/upload")
def valores_upload_page(request: Request):
    require_user(request)
    return render(request, "valores_upload.html", {})

@app.post("/valores/upload")
def valores_upload(request: Request, arquivo: UploadFile = File(...)):
    require_user(request)
    try:
        extracted = save_upload(arquivo)
        relatorio_id = import_values_report(extracted)
    except Exception as exc:
        return render(request, "valores_upload.html", {"error": f"Erro ao processar relatório de valores: {exc}"})
    return flash_redirect(f"/valores/{relatorio_id}", "Relatório de valores importado com sucesso.")

@app.get("/valores/{relatorio_id}")
def valores_detail(request: Request, relatorio_id: int):
    require_user(request)
    conn = get_conn()
    rel = conn.execute("SELECT * FROM relatorios_valores WHERE id=?", (relatorio_id,)).fetchone()
    if not rel:
        conn.close(); raise HTTPException(404)
    rows = conn.execute("SELECT * FROM valores_precatorios WHERE relatorio_id=? ORDER BY id ASC LIMIT 300", (relatorio_id,)).fetchall()
    conn.close()
    return render(request, "valores_detail.html", {"relatorio": rel, "rows": rows})

@app.get("/credores")
def credores(request: Request):
    require_user(request)
    conn = get_conn()
    rows = conn.execute("""
        SELECT l.id AS lista_id, p.processo_depre, p.processo_origem, p.natureza, p.devedora,
               c.credor_nome, c.tipo_participacao, c.status, c.observacao, c.link_esaj, c.created_at
        FROM consultas_esaj c
        JOIN precatorios p ON p.id=c.precatorio_id
        JOIN listas l ON l.id=p.lista_id
        ORDER BY c.id DESC LIMIT 300
    """).fetchall()
    conn.close()
    return render(request, "credores.html", {"rows": rows})
