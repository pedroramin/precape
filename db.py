{% extends 'base.html' %}
{% block title %}Relatório de valores{% endblock %}
{% block content %}
<div class="page-head"><div><h1>Relatório de valores #{{ relatorio.id }}</h1><p>{{ relatorio.nome_arquivo }}</p></div><a class="btn secondary" href="/valores">Voltar</a></div>
<div class="cards">
  <div class="card"><span>Registros</span><strong>{{ relatorio.total_registros }}</strong></div>
  <div class="card"><span>Saldo atualizado em</span><strong class="small-card-text">{{ relatorio.saldo_atualizado_em or '-' }}</strong></div>
  <div class="card span2"><span>Entidade</span><strong class="small-card-text">{{ relatorio.entidade or '-' }}</strong></div>
</div>
<section class="panel">
  <h2>Valores importados</h2>
  <p class="hint">Mostrando até 300 registros. O cruzamento com os nomes aparece dentro da tela da lista TJSP.</p>
  <table>
    <thead><tr><th>Processo DEPRE</th><th>Nat.</th><th>Nº Ordem</th><th>Ano</th><th>Valor pago</th><th>Saldo</th><th>Superpreferência</th></tr></thead>
    <tbody>
      {% for r in rows %}
      <tr><td>{{r.processo_depre}}</td><td>{{r.natureza}}</td><td>{{r.numero_ordem}}</td><td>{{r.ano_orcamentario}}</td><td>{{r.valor_pago|money_br}}</td><td><strong>{{r.saldo|money_br}}</strong></td><td>{{r.condicao_superpreferencia}}</td></tr>
      {% endfor %}
    </tbody>
  </table>
</section>
{% endblock %}
