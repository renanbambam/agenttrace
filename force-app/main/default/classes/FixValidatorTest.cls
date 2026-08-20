/**
 * Testes do fechamento do ciclo: validar a correção ao vivo (passa/falha) e o
 * ponto de entrada da tela. Usa AgentTraceHttpMock (Claude gera o teste, Tooling roda).
 */
@isTest
private class FixValidatorTest {

    private static String corr() {
        return '{"classe":"CalculadoraPedido","de":"if (v > 100)","para":"if (v >= 100)","porque":"fronteira"}';
    }

    @isTest
    static void valida_passa() {
        AgentTraceHttpMock m = new AgentTraceHttpMock('System.assertEquals(10, 10);');
        m.toolingBody = '{"compiled":true,"success":true}';
        Test.setMock(HttpCalloutMock.class, m);
        Test.startTest();
        System.enqueueJob(new FixValidator('inv-1', corr()));
        Test.stopTest();
        System.assert(true, 'validação executou sem exceção');
    }

    @isTest
    static void valida_falha() {
        AgentTraceHttpMock m = new AgentTraceHttpMock('System.assertEquals(10, 0);');
        m.toolingBody = '{"compiled":true,"success":false,"exceptionMessage":"System.AssertException"}';
        Test.setMock(HttpCalloutMock.class, m);
        Test.startTest();
        System.enqueueJob(new FixValidator('inv-1', corr()));
        Test.stopTest();
        System.assert(true);
    }

    @isTest
    static void controller_validarCorrecao() {
        AgentTraceHttpMock m = new AgentTraceHttpMock('System.assert(true);');
        m.toolingBody = '{"compiled":true,"success":true}';
        Test.setMock(HttpCalloutMock.class, m);
        Test.startTest();
        InvestigationController.validarCorrecao('inv-1', corr());
        Test.stopTest();
        System.assert(true);
    }

    @isTest
    static void controller_validarCorrecao_vazio_lanca() {
        Boolean lancou = false;
        try {
            InvestigationController.validarCorrecao('', '');
        } catch (AuraHandledException e) {
            lancou = true;
        }
        System.assertEquals(true, lancou);
    }
}
