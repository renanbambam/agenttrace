/**
 * Valida ao vivo uma correção autorizada pelo humano — FECHA o ciclo.
 *
 * Quando o usuário clica "Autorizar correção", este Queueable:
 *  1. pede à Claude um Apex anônimo que implementa a LÓGICA CORRIGIDA inline,
 *  2. roda ele ao vivo (executeAnonymous via Tooling API),
 *  3. publica os passos (o teste + o console + o veredito) pra tela reagir.
 *
 * NÃO faz deploy da classe: prova que a correção funciona, mas aplicar continua
 * sendo decisão humana (DECISOES.md, 2026-08-18).
 */
public with sharing class FixValidator implements Queueable, Database.AllowsCallouts {

    private final String investigationId;
    private final String correcaoJson;

    public FixValidator(String investigationId, String correcaoJson) {
        this.investigationId = investigationId;
        this.correcaoJson = correcaoJson;
    }

    public void execute(QueueableContext context) {
        // 1. Gera a verificação (callout à Claude). Se falhar, reporta e encerra.
        String testeApex;
        try {
            testeApex = ClaudeService.gerarVerificacao(correcaoJson);
        } catch (Exception e) {
            publishNarration('pensando', 'Você autorizou, mas não consegui montar a verificação da correção.');
            publishFixValidated(false, 'Falha ao gerar a verificação: ' + e.getMessage());
            return;
        }

        // 2. Roda a verificação (callout à Tooling), PRIMEIRO — antes de qualquer publish.
        ToolingService.RunResult r;
        String erroExec;
        try {
            r = ToolingService.executeAnonymous(testeApex);
        } catch (Exception e) {
            erroExec = e.getMessage();
        }

        // 3. Narra e mostra o teste da correção + o console.
        publishNarration('decisao', 'Você autorizou. Vou validar a correção rodando a lógica corrigida ao vivo.');
        publishTest('Validação da correção', testeApex);
        publishNarration('acao', 'Rodando a verificação da correção…');

        Boolean passou = false;
        if (erroExec != null) {
            publishTestResult('> Erro ao validar:\n' + erroExec);
            publishFixValidated(false, 'Não consegui rodar a verificação: ' + erroExec);
        } else if (r.compiled != true) {
            publishTestResult('> A verificação não compilou:\n' + r.compileProblem);
            publishFixValidated(false, 'A verificação não compilou.');
        } else if (r.success == true) {
            passou = true;
            publishTestResult('> Executado.\n[OK] A lógica corrigida passa no teste — correção validada.');
            publishNarration('descartado', 'A correção passou na verificação ao vivo. Pronta pra deploy.');
            publishFixValidated(true, 'A correção passa no teste ao vivo — validada e pronta para deploy.');
        } else {
            publishTestResult('> Executado.\n[FALHOU] ' + r.exceptionMessage);
            publishNarration('achado', 'A verificação da correção falhou: ' + r.exceptionMessage);
            publishFixValidated(false, 'A verificação falhou: ' + r.exceptionMessage);
        }
    }

    // --- publicação (mesma forma dos outros passos) ---

    private void publishNarration(String kind, String text) {
        EventBus.publish(new Investigation_Step__e(
            Investigation_Id__c = investigationId,
            Step_Type__c        = 'narration',
            Message__c          = kind,
            Payload__c          = text
        ));
    }

    private void publishTest(String titulo, String codigo) {
        EventBus.publish(new Investigation_Step__e(
            Investigation_Id__c = investigationId,
            Step_Type__c        = 'test',
            Message__c          = titulo,
            Payload__c          = codigo
        ));
    }

    private void publishTestResult(String output) {
        EventBus.publish(new Investigation_Step__e(
            Investigation_Id__c = investigationId,
            Step_Type__c        = 'test_result',
            Message__c          = 'console',
            Payload__c          = output
        ));
    }

    private void publishFixValidated(Boolean passou, String texto) {
        EventBus.publish(new Investigation_Step__e(
            Investigation_Id__c = investigationId,
            Step_Type__c        = 'fix_validated',
            Message__c          = passou ? 'ok' : 'fail',
            Payload__c          = texto
        ));
    }
}
