/**
 * Testes do canal seguro da Claude: parsing da decisão (JSON, com cerca markdown,
 * inválido), ping, e erro HTTP. Não faz callout real — usa AgentTraceHttpMock.
 */
@isTest
private class ClaudeServiceTest {

    @isTest
    static void decideNextStep_parseiaConcluir() {
        Test.setMock(HttpCalloutMock.class, new AgentTraceHttpMock('{"acao":"concluir","resumo":"ok"}'));
        Test.startTest();
        Map<String, Object> d = ClaudeService.decideNextStep('incidente', new List<String>());
        Test.stopTest();
        System.assertEquals('concluir', d.get('acao'));
    }

    @isTest
    static void decideNextStep_comAchados() {
        Test.setMock(HttpCalloutMock.class,
            new AgentTraceHttpMock('{"acao":"rodar","capacidade":"listar_classes","porque":"x"}'));
        Test.startTest();
        Map<String, Object> d = ClaudeService.decideNextStep('inc', new List<String>{ 'achado 1' });
        Test.stopTest();
        System.assertEquals('rodar', d.get('acao'));
    }

    @isTest
    static void parseia_comCercaMarkdown() {
        Test.setMock(HttpCalloutMock.class,
            new AgentTraceHttpMock('```json\n{"acao":"concluir","resumo":"y"}\n```'));
        Test.startTest();
        Map<String, Object> d = ClaudeService.decideNextStep('inc', null);
        Test.stopTest();
        System.assertEquals('concluir', d.get('acao'));
    }

    @isTest
    static void jsonInvalido_lancaExcecao() {
        Test.setMock(HttpCalloutMock.class, new AgentTraceHttpMock('isso nao e json'));
        Test.startTest();
        Boolean lancou = false;
        try {
            ClaudeService.decideNextStep('inc', null);
        } catch (Exception e) {
            lancou = true;
        }
        Test.stopTest();
        System.assertEquals(true, lancou);
    }

    @isTest
    static void ping_retornaTexto() {
        Test.setMock(HttpCalloutMock.class, new AgentTraceHttpMock('pong'));
        Test.startTest();
        String r = ClaudeService.ping('oi');
        Test.stopTest();
        System.assertEquals('pong', r);
    }

    @isTest
    static void http500_lancaExcecao() {
        AgentTraceHttpMock m = new AgentTraceHttpMock('x');
        m.claudeStatus = 500;
        Test.setMock(HttpCalloutMock.class, m);
        Test.startTest();
        Boolean lancou = false;
        try {
            ClaudeService.ping('oi');
        } catch (Exception e) {
            lancou = true;
        }
        Test.stopTest();
        System.assertEquals(true, lancou);
    }
}
