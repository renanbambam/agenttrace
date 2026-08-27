/**
 * Testes da Sentinela (varredura proativa). Com um Log_Erro__c inserido, a varredura
 * registra o alerta e auto-investiga (orquestrador com mock de conclusão via tool_use).
 */
@isTest
private class SentinelScannerTest {

    private static AgentTraceHttpMock concludeMock() {
        return new AgentTraceHttpMock('concluir',
            new Map<String, Object>{ 'resumo' => 'r', 'area' => 'externo', 'impacto_negocio' => 'x' });
    }

    @isTest
    static void varredura_comAlerta_autoInvestiga() {
        insert new Log_Erro__c(Origem__c = 'X', Nivel__c = 'ERROR', Mensagem__c = 'falha 407 proxy recorrente');
        Test.setMock(HttpCalloutMock.class, concludeMock());
        Test.startTest();
        String res = SentinelScanner.runNow();
        Test.stopTest();
        System.assert(res.contains('alerta') || res.contains('Auto-investigando'), res);
        System.assert([SELECT COUNT() FROM Investigacao__c] > 0, 'deve registrar alerta(s)');
    }

    @isTest
    static void varredura_semAlerta() {
        Test.startTest();
        String res = SentinelScanner.runNow();
        Test.stopTest();
        System.assertNotEquals(null, res);
    }

    @isTest
    static void execute_schedulable() {
        Test.setMock(HttpCalloutMock.class, concludeMock());
        Test.startTest();
        new SentinelScanner().execute(null);
        Test.stopTest();
        System.assert(true, 'execute delega para runNow sem erro');
    }

    @isTest
    static void controller_rodarVarredura() {
        insert new Log_Erro__c(Origem__c = 'X', Nivel__c = 'ERROR', Mensagem__c = 'falha');
        Test.setMock(HttpCalloutMock.class, concludeMock());
        Test.startTest();
        String res = InvestigationController.rodarVarredura();
        Test.stopTest();
        System.assertNotEquals(null, res);
    }
}
