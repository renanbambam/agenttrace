/**
 * Roda uma verificação descartável (Apex anônimo) ao vivo, via a Tooling API do
 * PRÓPRIO org — o self-callout. A auth vem da Named Credential "OrgTooling"
 * (fluxo Client Credentials; chave/segredo no cofre da External Credential).
 *
 * Isto é o que torna o agente capaz de PROVAR um bug executando, não só lendo.
 */
public with sharing class ToolingService {

    private static final String NAMED_CREDENTIAL = 'callout:OrgTooling';
    private static final String API_VERSION = 'v67.0';

    public class ToolingException extends Exception {}

    /** Resultado real de uma execução anônima. */
    public class RunResult {
        public Boolean compiled;
        public Boolean success;
        public String compileProblem;   // erro de compilação, se houver
        public String exceptionMessage; // exceção em runtime (ex.: AssertException)
        public Integer line;
    }

    public static RunResult executeAnonymous(String apexBody) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(
            NAMED_CREDENTIAL + '/services/data/' + API_VERSION +
            '/tooling/executeAnonymous/?anonymousBody=' +
            EncodingUtil.urlEncode(apexBody, 'UTF-8')
        );
        req.setMethod('GET');
        req.setTimeout(120000);

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            throw new ToolingException(
                'Tooling HTTP ' + res.getStatusCode() + ': ' + res.getBody()
            );
        }

        Map<String, Object> m = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        RunResult r = new RunResult();
        r.compiled = (Boolean) m.get('compiled');
        r.success = (Boolean) m.get('success');
        r.compileProblem = (String) m.get('compileProblem');
        r.exceptionMessage = (String) m.get('exceptionMessage');
        r.line = (Integer) m.get('line');
        return r;
    }
}
