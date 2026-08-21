/**
 * Cobertura do harness de eval. Usa mock (não faz callout real) — só garante que
 * run() executa e devolve o placar. O eval REAL roda via scripts/apex/eval.apex.
 */
@isTest
private class AgentEvalTest {

    @isTest
    static void run_devolvePlacar() {
        Test.setMock(HttpCalloutMock.class,
            new AgentTraceHttpMock('{"acao":"concluir","resumo":"ok","area":"codigo"}'));
        Test.startTest();
        List<String> out = AgentEval.run();
        Test.stopTest();
        System.assert(!out.isEmpty());
        System.assert(out[out.size() - 1].startsWith('PLACAR:'));
    }
}
