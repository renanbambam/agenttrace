/**
 * Capacidade real: lê os erros registrados no objeto Log_Erro__c (últimos 7 dias).
 *
 * Só leitura (SOQL), sem efeito colateral. Corresponde ao nó "Log de erro" do mapa.
 * É por aqui que o agente descobre falhas que já foram REGISTRADAS — inclusive de
 * integração — pra depois cruzar com a sonda ao vivo ou concluir a causa.
 */
public with sharing class ErrorLogCapability implements InvestigationCapability {

    private static final String NODE_LABEL = 'Log de erro';

    public CapabilityResult run() {
        List<Log_Erro__c> logs = [
            SELECT Origem__c, Nivel__c, Mensagem__c
            FROM Log_Erro__c
            WHERE CreatedDate = LAST_N_DAYS:7
            ORDER BY CreatedDate DESC
            LIMIT 10
        ];

        if (logs.isEmpty()) {
            return new CapabilityResult(false, NODE_LABEL, 'Nenhum erro registrado nos logs recentes.');
        }

        List<String> linhas = new List<String>();
        for (Log_Erro__c l : logs) {
            linhas.add('[' + l.Origem__c + '] ' + l.Mensagem__c);
        }
        return new CapabilityResult(
            true,
            NODE_LABEL,
            logs.size() + ' erro(s) registrado(s) nos logs: ' + String.join(linhas, ' || ')
        );
    }
}
