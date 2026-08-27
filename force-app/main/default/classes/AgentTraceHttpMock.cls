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

    // Modo tool_use: se toolName != null, a resposta da Claude vem como tool_use.
    public String toolName;
    public Map<String, Object> toolInput;

    public class MockCalloutException extends Exception {}

    public AgentTraceHttpMock(String claudeText) {
        this.claudeText = claudeText;
    }

    /** Atalho pra mockar uma decisão tool_use. */
    public AgentTraceHttpMock(String toolName, Map<String, Object> toolInput) {
        this.toolName = toolName;
        this.toolInput = (toolInput == null) ? new Map<String, Object>() : toolInput;
    }

    public HttpResponse respond(HttpRequest req) {
        String ep = req.getEndpoint();
        HttpResponse res = new HttpResponse();
        res.setHeader('Content-Type', 'application/json');

        if (ep.contains('/v1/messages')) {
            res.setStatusCode(claudeStatus);
            String usage = ',"usage":{"input_tokens":10,"output_tokens":5}';
            if (toolName != null) {
                res.setBody('{"content":[{"type":"tool_use","id":"toolu_1","name":'
                    + JSON.serialize(toolName) + ',"input":' + JSON.serialize(toolInput)
                    + '}],"stop_reason":"tool_use"' + usage + '}');
            } else {
                res.setBody('{"content":[{"type":"text","text":' + JSON.serialize(claudeText)
                    + '}],"stop_reason":"end_turn"' + usage + '}');
            }
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
