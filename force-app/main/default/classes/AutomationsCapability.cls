/**
 * Capacidade real: lista as automações do org — flows ativos e triggers.
 *
 * Só leitura (SOQL em FlowDefinitionView e ApexTrigger). Flows e triggers são onde
 * muita lógica de negócio (e muito bug silencioso) vive num org enterprise. Cada
 * consulta é isolada em try/catch pra que falta de acesso a uma não derrube a outra.
 */
public with sharing class AutomationsCapability implements InvestigationCapability {

    public CapabilityResult run() {
        List<String> itens = new List<String>();

        try {
            for (FlowDefinitionView f : [
                SELECT Label, ProcessType FROM FlowDefinitionView WHERE IsActive = true LIMIT 50
            ]) {
                itens.add('Flow ativo: ' + f.Label + ' (' + f.ProcessType + ')');
            }
        } catch (Exception e) {
            /* sem acesso a FlowDefinitionView — ignora e segue */
        }

        try {
            for (ApexTrigger t : [
                SELECT Name, TableEnumOrId, Status FROM ApexTrigger WHERE NamespacePrefix = null LIMIT 50
            ]) {
                itens.add('Trigger: ' + t.Name + ' em ' + t.TableEnumOrId + ' (' + t.Status + ')');
            }
        } catch (Exception e) {
            /* sem acesso a ApexTrigger — ignora */
        }

        if (itens.isEmpty()) {
            return new CapabilityResult(false, '', 'Nenhuma automação (flow ativo ou trigger) encontrada.');
        }
        return new CapabilityResult(true, '', itens.size() + ' automação(ões): ' + String.join(itens, ' | '));
    }
}
