/**
 * Ponto de entrada da investigação, chamado pela tela (LWC).
 *
 * No esqueleto, startDemo() dispara uma sequência FICTÍCIA de passos só para
 * validar o cano ponta-a-ponta (Apex publica -> barramento -> tela reage).
 * Devolve o investigationId para a tela filtrar os eventos que são dela.
 */
public with sharing class InvestigationController {

    @AuraEnabled
    public static String startDemo() {
        String investigationId = 'demo-' + String.valueOf(DateTime.now().getTime());

        List<InvestigationStepPublisher.StepDef> steps =
            new List<InvestigationStepPublisher.StepDef>{
                new InvestigationStepPublisher.StepDef('node_pulse', 'Jobs assíncronos'),
                new InvestigationStepPublisher.StepDef('node_clear', 'Jobs assíncronos'),
                new InvestigationStepPublisher.StepDef('node_pulse', 'Config recente'),
                new InvestigationStepPublisher.StepDef('node_hit',   'Config recente'),
                new InvestigationStepPublisher.StepDef('summary',
                    'Mudança de config recente bate com o horário do problema.')
            };

        System.enqueueJob(new InvestigationStepPublisher(investigationId, steps, 0));
        return investigationId;
    }
}
