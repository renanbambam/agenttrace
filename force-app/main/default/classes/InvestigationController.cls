/**
 * Ponto de entrada da investigação, chamado pela tela (LWC).
 *
 * start(incident): a investigação REAL, guiada pela Claude (loop de raciocínio).
 * startDemo(): a sequência fixa antiga (mantida como comparação).
 * Ambas devolvem o investigationId para a tela filtrar os eventos que são dela.
 */
public with sharing class InvestigationController {

    /** Investigação real: a Claude decide os passos a partir do texto do incidente. */
    @AuraEnabled
    public static String start(String incident) {
        if (String.isBlank(incident)) {
            throw new AuraHandledException('Descreva o incidente antes de investigar.');
        }
        return InvestigationOrchestrator.start(incident);
    }

    /**
     * Fecha o ciclo: o humano autorizou a correção -> valida ela ao vivo (sem deploy).
     * Recebe o id da investigação e a correção (JSON: classe, de, para, porque).
     */
    @AuraEnabled
    public static void validarCorrecao(String investigationId, String correcaoJson) {
        if (String.isBlank(investigationId) || String.isBlank(correcaoJson)) {
            throw new AuraHandledException('Faltam dados da correção para validar.');
        }
        System.enqueueJob(new FixValidator(investigationId, correcaoJson));
    }

    /** Demo fixa (não usa Claude): pulsa/acende os nós numa sequência pré-definida. */
    @AuraEnabled
    public static String startDemo() {
        String investigationId = 'demo-' + String.valueOf(DateTime.now().getTime());

        CapabilityResult jobs = new FailedJobsCapability().run();
        CapabilityResult config = new ConfigChangesCapability().run();

        List<InvestigationStepPublisher.StepDef> steps =
            new List<InvestigationStepPublisher.StepDef>{
                new InvestigationStepPublisher.StepDef('node_pulse', 'Jobs assíncronos'),
                new InvestigationStepPublisher.StepDef(jobs.suspect ? 'node_hit' : 'node_clear', 'Jobs assíncronos'),
                new InvestigationStepPublisher.StepDef('node_pulse', 'Config recente'),
                new InvestigationStepPublisher.StepDef(config.suspect ? 'node_hit' : 'node_clear', 'Config recente'),
                new InvestigationStepPublisher.StepDef('summary',
                    'Achados reais — ' + jobs.message + ' ' + config.message)
            };

        System.enqueueJob(new InvestigationStepPublisher(investigationId, steps, 0));
        return investigationId;
    }
}
