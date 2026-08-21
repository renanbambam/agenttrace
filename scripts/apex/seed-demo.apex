/**
 * Semeia os dados de demonstração do AgentTrace (idempotente — limpa antes).
 * Rodar:  sf apex run --file scripts/apex/seed-demo.apex -o agenttrace-org
 *
 * 1) Log_Erro__c: falhas de integração externa (407 proxy / timeout) — cenário C.
 * 2) Pedido__c: 25 pedidos, 12 em exatamente R$ 100 sem desconto (afetados pelo bug) — cenário D.
 */

// --- 1) Logs de erro (integração externa falhando) ---
delete [SELECT Id FROM Log_Erro__c WHERE Origem__c = 'SincronizacaoParceiro'];
insert new List<Log_Erro__c>{
    new Log_Erro__c(Origem__c = 'SincronizacaoParceiro', Nivel__c = 'ERROR',
        Mensagem__c = 'System.CalloutException: 407 Proxy Authentication Required — falha ao conectar em https://api.logistica-parceiro.com/sync'),
    new Log_Erro__c(Origem__c = 'SincronizacaoParceiro', Nivel__c = 'ERROR',
        Mensagem__c = 'System.CalloutException: 407 Proxy Authentication Required — falha ao conectar em https://api.logistica-parceiro.com/sync'),
    new Log_Erro__c(Origem__c = 'SincronizacaoParceiro', Nivel__c = 'ERROR',
        Mensagem__c = 'System.CalloutException: Read timed out apos 10000ms ao conectar em https://api.logistica-parceiro.com/sync')
};

// --- 2) Pedidos (impacto do bug de desconto nos dados) ---
delete [SELECT Id FROM Pedido__c];
List<Pedido__c> ps = new List<Pedido__c>();
// 12 afetados: valor 100 exato, desconto 0 (deveria ser 10) — o bug do operador >
for (Integer i = 0; i < 12; i++) {
    ps.add(new Pedido__c(Valor__c = 100, Desconto__c = 0, Status__c = 'Fechado',
        Cliente__c = 'Empresa ' + i, Email__c = 'cliente' + i + '@exemplo.com'));
}
// 8 corretos: valor 150, desconto 15 (10%)
for (Integer i = 0; i < 8; i++) {
    ps.add(new Pedido__c(Valor__c = 150, Desconto__c = 15, Status__c = 'Fechado',
        Cliente__c = 'Empresa A' + i, Email__c = 'a' + i + '@exemplo.com'));
}
// 5 corretos: valor 80 (abaixo do limite), desconto 0
for (Integer i = 0; i < 5; i++) {
    ps.add(new Pedido__c(Valor__c = 80, Desconto__c = 0, Status__c = 'Fechado',
        Cliente__c = 'Empresa B' + i, Email__c = 'b' + i + '@exemplo.com'));
}
insert ps;

System.debug('SEED OK — logs=' + [SELECT COUNT() FROM Log_Erro__c WHERE Origem__c = 'SincronizacaoParceiro']
    + ' pedidos=' + [SELECT COUNT() FROM Pedido__c]
    + ' afetados=' + [SELECT COUNT() FROM Pedido__c WHERE Valor__c = 100 AND Desconto__c = 0]);
