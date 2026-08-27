/**
 * Aplica DE VERDADE uma correção autorizada — o "fechar o ciclo" completo.
 *
 * Depois que o humano autoriza E a correção é validada ao vivo, este Queueable
 * aplica a mudança no código do org via a Tooling API (fluxo MetadataContainer →
 * ApexClassMember → ContainerAsyncRequest). Pega o corpo atual da classe, troca o
 * trecho "de" pelo "para", e deploya. Nunca roda sem autorização humana.
 */
public with sharing class CodeDeployer implements Queueable, Database.AllowsCallouts {

    private static final String EP = 'callout:OrgTooling/services/data/v67.0/tooling';

    private final String investigationId;
    private final String correcaoJson;

    public class DeployException extends Exception {}

    public CodeDeployer(String investigationId, String correcaoJson) {
        this.investigationId = investigationId;
        this.correcaoJson = correcaoJson;
    }

    public void execute(QueueableContext ctx) {
        Map<String, Object> c;
        try {
            c = (Map<String, Object>) JSON.deserializeUntyped(correcaoJson);
        } catch (Exception e) {
            publishApplied(false, 'Correção inválida.');
            return;
        }
        String classe = (String) c.get('classe');
        String de = (String) c.get('de');
        String para = (String) c.get('para');

        List<ApexClass> rows = [
            SELECT Id, Body FROM ApexClass WHERE Name = :classe AND NamespacePrefix = null LIMIT 1
        ];
        if (rows.isEmpty()) {
            publishApplied(false, 'Classe ' + classe + ' não encontrada.');
            return;
        }
        String currentBody = rows[0].Body;
        if (String.isNotBlank(de) && !currentBody.contains(de)) {
            publishApplied(false, 'Não achei o trecho exato a trocar no código atual — não vou aplicar às cegas.');
            return;
        }
        String newBody = String.isBlank(de) ? currentBody : currentBody.replace(de, para);
        String classId = rows[0].Id;

        try {
            String containerId = toolingCreate('MetadataContainer',
                new Map<String, Object>{ 'Name' => 'at_deploy_' + DateTime.now().getTime() });
            toolingCreate('ApexClassMember',
                new Map<String, Object>{ 'MetadataContainerId' => containerId, 'ContentEntityId' => classId, 'Body' => newBody });
            String reqId = toolingCreate('ContainerAsyncRequest',
                new Map<String, Object>{ 'MetadataContainerId' => containerId, 'IsCheckOnly' => false });

            Map<String, Object> fim = pollDeploy(reqId);
            String state = (String) fim.get('State');
            if (state == 'Completed') {
                publishApplied(true, 'Correção aplicada e deployada em ' + classe + '. O código do org foi atualizado.');
            } else {
                String err = (String) fim.get('ErrorMsg');
                publishApplied(false, 'O deploy não completou (estado: ' + state + ')'
                    + (String.isBlank(err) ? '.' : ': ' + err));
            }
        } catch (Exception e) {
            publishApplied(false, 'Falha ao aplicar: ' + e.getMessage());
        }
    }

    private String toolingCreate(String sobjectName, Map<String, Object> payload) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(EP + '/sobjects/' + sobjectName);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setBody(JSON.serialize(payload));
        req.setTimeout(120000);
        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() >= 300) {
            throw new DeployException(sobjectName + ' HTTP ' + res.getStatusCode() + ': ' + res.getBody());
        }
        Map<String, Object> m = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        return (String) m.get('id');
    }

    // Sem sleep em Apex: as próprias chamadas dão o tempo. Deploy de 1 classe é rápido.
    private Map<String, Object> pollDeploy(String reqId) {
        Map<String, Object> m = new Map<String, Object>{ 'State' => 'Queued' };
        for (Integer i = 0; i < 25; i++) {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(EP + '/sobjects/ContainerAsyncRequest/' + reqId);
            req.setMethod('GET');
            req.setTimeout(120000);
            HttpResponse res = new Http().send(req);
            m = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            String state = (String) m.get('State');
            if (state != 'Queued' && state != 'InProgress') {
                return m;
            }
        }
        return m;
    }

    private void publishApplied(Boolean ok, String texto) {
        EventBus.publish(new Investigation_Step__e(
            Investigation_Id__c = investigationId,
            Step_Type__c        = 'fix_applied',
            Message__c          = ok ? 'ok' : 'fail',
            Payload__c          = texto
        ));
    }
}
