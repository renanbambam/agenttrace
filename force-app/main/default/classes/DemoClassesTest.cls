/**
 * Testes das classes de DEMO. Documentam o comportamento (com bug) que o agente
 * investiga — asserções sobre o valor REAL, provando o bug de fronteira.
 */
@isTest
private class DemoClassesTest {

    @isTest
    static void calculadora_bugFronteira100() {
        // Bug: 100 exato NÃO recebe desconto (usa > em vez de >=).
        System.assert(CalculadoraPedido.calcularDesconto(100) == 0, '100 nao recebe desconto (bug)');
        System.assert(CalculadoraPedido.calcularDesconto(150) == 15, '150 recebe 10% = 15');
    }

    @isTest
    static void validadorEstoque_bugFronteira() {
        System.assertEquals(false, ValidadorEstoque.temEstoque(5, 5), 'igual nega indevidamente (bug)');
        System.assertEquals(true, ValidadorEstoque.temEstoque(6, 5));
    }

    @isTest
    static void relatorioVendas_executa() {
        List<Datetime> vendas = new List<Datetime>{ Datetime.now(), Datetime.now().addDays(-1) };
        Integer n = RelatorioVendas.vendasDeHoje(vendas);
        System.assert(n >= 0);
    }

    @isTest
    static void integracaoPagamentos_cobrarComMock() {
        Test.setMock(HttpCalloutMock.class, new SucessoMock());
        Test.startTest();
        Integer status = IntegracaoPagamentos.cobrar(100);
        Test.stopTest();
        System.assertEquals(200, status);
    }

    private class SucessoMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"ok":true}');
            return res;
        }
    }
}
