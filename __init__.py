{% extends 'base.html' %}
{% block title %}Enviar valores{% endblock %}
{% block content %}
<div class="page-head"><div><h1>Enviar relatório de valores</h1><p>Envie o PDF “Consulta do Total da Dívida Anual - Detalhado” baixado no TJSP.</p></div></div>
{% if error %}<div class="alert danger">{{ error }}</div>{% endif %}
<section class="panel">
  <form method="post" action="/valores/upload" enctype="multipart/form-data" class="upload-box">
    <input type="file" name="arquivo" accept=".pdf,.zip" required>
    <button type="submit">Importar valores</button>
  </form>
  <p class="hint">Esse relatório é usado para cruzar o Processo DEPRE com Valor Pago e Saldo atualizado.</p>
</section>
{% endblock %}
