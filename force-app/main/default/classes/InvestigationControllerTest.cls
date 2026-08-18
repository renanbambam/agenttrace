/**
 * Testes do ponto de entrada da tela: valida incidente vazio, dispara a investigação
 * real (com a Claude concluindo via mock) e a demo fixa.
 */
@isTest
private class InvestigationControllerTest {

    @isTest
    static void start_vazio_lanca() {
        Boolean lancou = false;
        try {
            InvestigationController.start('   ');
        } catch (AuraHandledException e) {
            lancou = true;
        }
        System.assertEquals(true, lancou);
    }

    @isTest
    static void start_valido_retornaId() {
        Test.setMock(HttpCalloutMock.class,
            new AgentTraceHttpMock('{"acao":"concluir","resumo":"fim"}'));
        Test.startTest();
        String id = InvestigationController.start('meu incidente');
        Test.stopTest();
        System.assert(id != null && id.startsWith('inv-'));
    }

    @isTest
    static void startDemo_retornaId() {
        Test.startTest();
        String id = InvestigationController.startDemo();
        Test.stopTest();
        System.assert(id.startsWith('demo-'));
    }
}
