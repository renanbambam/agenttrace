/**
 * Testes do loop de raciocínio. Cada método finge uma decisão diferente da Claude
 * (via AgentTraceHttpMock) e verifica que o ramo correspondente roda sem erro.
 * O encadeamento é pulado em teste (enqueueNext -> Test.isRunningTest), então cada
 * execução cobre exatamente um passo.
 */
@isTest
private class InvestigationOrchestratorTest {

    private static void runWith(String claudeText) {
        Test.setMock(HttpCalloutMock.class, new AgentTraceHttpMock(claudeText));
        Test.startTest();
        InvestigationOrchestrator.start('incidente de teste');
        Test.stopTest();
    }

    @isTest
    static void conclui() {
        runWith('{"acao":"concluir","resumo":"conclusao de teste"}');
    }

    @isTest
    static void concluiComCorrecao() {
        runWith('{"acao":"concluir","resumo":"r","correcao":' +
            '{"classe":"CalculadoraPedido","de":"if (v > 100)","para":"if (v >= 100)","porque":"fronteira"}}');
    }

    @isTest
    static void listaClasses() {
        runWith('{"acao":"rodar","capacidade":"listar_classes","porque":"x"}');
    }

    @isTest
    static void inspecionaCodigo() {
        runWith('{"acao":"rodar","capacidade":"inspecionar_codigo","alvo":"CalculadoraPedido","porque":"x"}');
    }

    @isTest
    static void inspecionaCodigo_classeInexistente() {
        runWith('{"acao":"rodar","capacidade":"inspecionar_codigo","alvo":"NaoExiste","porque":"x"}');
    }

    @isTest
    static void testaCodigo() {
        runWith('{"acao":"rodar","capacidade":"testar_codigo","codigo_teste":"System.assert(false);","porque":"x"}');
    }

    @isTest
    static void sondaIntegracao_ok() {
        runWith('{"acao":"rodar","capacidade":"sondar_integracao","endpoint":"https://api.exemplo.com/x","porque":"x"}');
    }

    @isTest
    static void sondaIntegracao_falha() {
        AgentTraceHttpMock m = new AgentTraceHttpMock(
            '{"acao":"rodar","capacidade":"sondar_integracao","endpoint":"https://api.exemplo.com/x","porque":"x"}');
        m.probeThrow = true;
        Test.setMock(HttpCalloutMock.class, m);
        Test.startTest();
        InvestigationOrchestrator.start('inc');
        Test.stopTest();
    }

    @isTest
    static void sinalLogErro() {
        insert new Log_Erro__c(Origem__c = 'X', Nivel__c = 'ERROR', Mensagem__c = 'falha');
        runWith('{"acao":"rodar","capacidade":"log_erro","porque":"x"}');
    }

    @isTest
    static void capacidadeDesconhecida() {
        runWith('{"acao":"rodar","capacidade":"nao_existe","porque":"x"}');
    }

    @isTest
    static void decisaoNaoReconhecida() {
        runWith('{"acao":"pensar","porque":"x"}');
    }

    @isTest
    static void falhaOperacional() {
        AgentTraceHttpMock m = new AgentTraceHttpMock('x');
        m.claudeStatus = 500;
        Test.setMock(HttpCalloutMock.class, m);
        Test.startTest();
        InvestigationOrchestrator.start('inc');
        Test.stopTest();
    }

    @isTest
    static void buscaNoCodigo() {
        runWith('{"acao":"rodar","capacidade":"buscar_no_codigo","termo":"desconto","porque":"x"}');
    }

    @isTest
    static void buscaNoCodigo_semResultado() {
        runWith('{"acao":"rodar","capacidade":"buscar_no_codigo","termo":"zzz_nao_existe_zzz","porque":"x"}');
    }

    @isTest
    static void schemaObjeto() {
        runWith('{"acao":"rodar","capacidade":"schema_objeto","objeto":"Log_Erro__c","porque":"x"}');
    }

    @isTest
    static void schemaObjeto_inexistente() {
        runWith('{"acao":"rodar","capacidade":"schema_objeto","objeto":"NaoExiste__x","porque":"x"}');
    }

    @isTest
    static void consultarDados_ok() {
        insert new Log_Erro__c(Origem__c = 'X', Nivel__c = 'ERROR', Mensagem__c = 'falha');
        runWith('{"acao":"rodar","capacidade":"consultar_dados","soql":"SELECT Id, Origem__c FROM Log_Erro__c LIMIT 5","porque":"x"}');
    }

    @isTest
    static void consultarDados_naoSelect_recusa() {
        runWith('{"acao":"rodar","capacidade":"consultar_dados","soql":"DELETE FROM Log_Erro__c","porque":"x"}');
    }

    @isTest
    static void consultarDados_erro() {
        runWith('{"acao":"rodar","capacidade":"consultar_dados","soql":"SELECT Id FROM ObjetoInexistente__c","porque":"x"}');
    }

    @isTest
    static void localizeIntegration_classificaTodos() {
        System.assert(InvestigationOrchestrator.localizeIntegration('Unauthorized endpoint').contains('org'));
        System.assert(InvestigationOrchestrator.localizeIntegration('HTTP 407 proxy').toLowerCase().contains('proxy'));
        System.assert(InvestigationOrchestrator.localizeIntegration('Read timed out').toLowerCase().contains('timeout'));
        System.assert(InvestigationOrchestrator.localizeIntegration('UnknownHost api.x.com').toLowerCase().contains('dns'));
        System.assertNotEquals(null, InvestigationOrchestrator.localizeIntegration('algo estranho'));
    }
}
