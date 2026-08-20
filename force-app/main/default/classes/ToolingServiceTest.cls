/**
 * Testes do canal da Tooling API (executeAnonymous): parsing do RunResult e erro HTTP.
 */
@isTest
private class ToolingServiceTest {

    @isTest
    static void executeAnonymous_parseiaResultado() {
        AgentTraceHttpMock m = new AgentTraceHttpMock('x');
        m.toolingBody = '{"compiled":true,"success":false,"exceptionMessage":"System.AssertException: Expected 10 Actual 0","line":2}';
        Test.setMock(HttpCalloutMock.class, m);
        Test.startTest();
        ToolingService.RunResult r = ToolingService.executeAnonymous('System.assert(false);');
        Test.stopTest();
        System.assertEquals(true, r.compiled);
        System.assertEquals(false, r.success);
        System.assert(r.exceptionMessage.contains('AssertException'));
        System.assertEquals(2, r.line);
    }

    @isTest
    static void naoOk_lancaExcecao() {
        Test.setMock(HttpCalloutMock.class, new ToolingErroMock());
        Test.startTest();
        Boolean lancou = false;
        try {
            ToolingService.executeAnonymous('x');
        } catch (ToolingService.ToolingException e) {
            lancou = true;
        }
        Test.stopTest();
        System.assertEquals(true, lancou);
    }

    @isTest
    static void getLogBody_retornaCorpo() {
        Test.setMock(HttpCalloutMock.class, new AgentTraceHttpMock('x'));
        Test.startTest();
        String body = ToolingService.getLogBody('07Lxx0000000001AAA');
        Test.stopTest();
        System.assertNotEquals(null, body);
    }

    private class ToolingErroMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(500);
            res.setBody('erro interno');
            return res;
        }
    }
}
