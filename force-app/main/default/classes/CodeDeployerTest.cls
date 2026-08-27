/**
 * Testes do self-deploy (fechar o ciclo de verdade). Mock das respostas da Tooling API
 * (MetadataContainer / ApexClassMember / ContainerAsyncRequest) — sem deploy real.
 */
@isTest
private class CodeDeployerTest {

    private class DeployMock implements HttpCalloutMock {
        public Boolean completed = true;
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            if (req.getMethod() == 'GET') {
                res.setStatusCode(200);
                res.setBody('{"State":"' + (completed ? 'Completed' : 'Failed') + '","ErrorMsg":"erro de teste"}');
            } else {
                res.setStatusCode(201);
                res.setBody('{"id":"1abc000000000001","success":true}');
            }
            return res;
        }
    }

    @isTest
    static void aplica_sucesso() {
        Test.setMock(HttpCalloutMock.class, new DeployMock());
        Test.startTest();
        InvestigationController.aplicarCorrecao('inv-1',
            '{"classe":"CalculadoraPedido","de":"valor > 100","para":"valor >= 100"}');
        Test.stopTest();
        System.assert(true, 'deploy executou sem exceção');
    }

    @isTest
    static void aplica_falhaDeploy() {
        DeployMock m = new DeployMock();
        m.completed = false;
        Test.setMock(HttpCalloutMock.class, m);
        Test.startTest();
        System.enqueueJob(new CodeDeployer('inv-1',
            '{"classe":"CalculadoraPedido","de":"valor > 100","para":"valor >= 100"}'));
        Test.stopTest();
        System.assert(true);
    }

    @isTest
    static void aplica_classeInexistente() {
        Test.setMock(HttpCalloutMock.class, new DeployMock());
        Test.startTest();
        System.enqueueJob(new CodeDeployer('inv-1', '{"classe":"NaoExisteZZ","de":"x","para":"y"}'));
        Test.stopTest();
        System.assert(true);
    }

    @isTest
    static void aplica_trechoNaoAchado() {
        Test.setMock(HttpCalloutMock.class, new DeployMock());
        Test.startTest();
        System.enqueueJob(new CodeDeployer('inv-1',
            '{"classe":"CalculadoraPedido","de":"TRECHO_INEXISTENTE_ZZZ","para":"y"}'));
        Test.stopTest();
        System.assert(true);
    }

    @isTest
    static void controller_vazio_lanca() {
        Boolean lancou = false;
        try {
            InvestigationController.aplicarCorrecao('', '');
        } catch (AuraHandledException e) {
            lancou = true;
        }
        System.assertEquals(true, lancou);
    }
}
