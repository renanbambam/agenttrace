/**
 * Publicador encadeado dos passos de uma investigação.
 *
 * Cada execução publica UM passo e, se ainda houver passo depois, se
 * re-enfileira para o próximo índice. Como cada execução é uma transação
 * assíncrona separada, os eventos chegam genuinamente espaçados no tempo —
 * espelhando o sistema real, onde cada passo leva tempo porque faz trabalho
 * de verdade. (Decisão registrada em DECISOES.md, 2026-08-15.)
 *
 * No esqueleto os passos são fictícios; a forma async é a mesma que as
 * capacidades reais vão usar.
 */
public with sharing class InvestigationStepPublisher implements Queueable {

    /** Dado simples de um passo. Só campos de texto -> estado do job serializável. */
    public class StepDef {
        public String stepType;
        public String message;
        public StepDef(String stepType, String message) {
            this.stepType = stepType;
            this.message = message;
        }
    }

    private final String investigationId;
    private final List<StepDef> steps;
    private final Integer index;

    public InvestigationStepPublisher(String investigationId, List<StepDef> steps, Integer index) {
        this.investigationId = investigationId;
        this.steps = steps;
        this.index = index;
    }

    public void execute(QueueableContext context) {
        StepDef current = steps[index];

        EventBus.publish(new Investigation_Step__e(
            Investigation_Id__c = investigationId,
            Step_Type__c        = current.stepType,
            Message__c          = current.message
        ));

        Integer next = index + 1;
        if (next < steps.size() && !Test.isRunningTest()) {
            System.enqueueJob(new InvestigationStepPublisher(investigationId, steps, next));
        }
    }
}
