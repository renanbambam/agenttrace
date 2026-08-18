/**
 * Integração de DEMO com um parceiro externo de pagamentos.
 *
 * Existe pra o agente ter um alvo de investigação de INTEGRAÇÃO real: o método
 * cobrar() dispara um callout ao endpoint do parceiro. Na demo, esse endpoint
 * NÃO está liberado em Remote Site Settings, então o callout falha com
 * "Unauthorized endpoint" — um problema de configuração DENTRO do org.
 *
 * O agente nunca roda cobrar() (é POST, mexeria no sistema externo): ele lê a
 * classe, extrai o ENDPOINT, e dispara uma SONDA GET (só leitura) pra observar
 * a falha com segurança.
 */
public with sharing class IntegracaoPagamentos {

    // Endpoint do parceiro. Precisa estar em Remote Site Settings pra o callout sair do org.
    public static final String ENDPOINT = 'https://api.parceiro-pagamentos.com/v1/cobranca';

    /** Dispara a cobrança no parceiro. Retorna o status HTTP. */
    public static Integer cobrar(Decimal valor) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(ENDPOINT);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setBody('{"valor":' + valor + '}');
        HttpResponse res = new Http().send(req);
        return res.getStatusCode();
    }
}
