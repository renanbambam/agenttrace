/**
 * Mock HTTP compartilhado dos testes. Roteia por endpoint:
 *  - /v1/messages            -> resposta da Claude (texto configurável)
 *  - /tooling/executeAnonymous -> resposta da Tooling API (RunResult)
 *  - qualquer outro          -> a sonda direta ao endpoint do parceiro
 *
 * Assim um único mock cobre os três callouts que o agente faz.
 */
@isTest
public class AgentTraceHttpMock implements HttpCalloutMock {

    public String claudeText;
    public Integer claudeStatus = 200;
    public Integer probeStatus = 200;
    public Boolean probeThrow = false;
    public String toolingBody;

    public class MockCalloutException extends Exception {}

    public AgentTraceHttpMock(String claudeText) {
        this.claudeText = claudeText;
    }

    public HttpResponse respond(HttpRequest req) {
        String ep = req.getEndpoint();
        HttpResponse res = new HttpResponse();
        res.setHeader('Content-Type', 'application/json');

        if (ep.contains('/v1/messages')) {
            res.setStatusCode(claudeStatus);
            res.setBody('{"content":[{"type":"text","text":' + JSON.serialize(claudeText) + '}]}');
            return res;
        }
        if (ep.contains('/tooling/executeAnonymous')) {
            res.setStatusCode(200);
            res.setBody(toolingBody != null ? toolingBody
                : '{"compiled":true,"success":false,"exceptionMessage":"System.AssertException: Assertion Failed","line":1}');
            return res;
        }
        // Sonda direta ao endpoint externo.
        if (probeThrow) {
            throw new MockCalloutException(
                'Unauthorized endpoint, please check Setup->Security->Remote site settings.');
        }
        res.setStatusCode(probeStatus);
        res.setBody('{}');
        return res;
    }
}
