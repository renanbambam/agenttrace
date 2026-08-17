/**
 * Resultado padronizado de uma capacidade de investigação.
 *
 * suspect   -> a capacidade encontrou algo suspeito?
 * nodeLabel -> a qual nó do mapa este resultado pertence
 * message   -> texto do achado (com evidência específica, nunca vago)
 */
public class CapabilityResult {
    @AuraEnabled public Boolean suspect { get; set; }
    @AuraEnabled public String nodeLabel { get; set; }
    @AuraEnabled public String message { get; set; }

    public CapabilityResult(Boolean suspect, String nodeLabel, String message) {
        this.suspect = suspect;
        this.nodeLabel = nodeLabel;
        this.message = message;
    }
}
