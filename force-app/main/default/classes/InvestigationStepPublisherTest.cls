/**
 * Teste do publicador encadeado (esqueleto): publica um passo sem encadear em teste.
 */
@isTest
private class InvestigationStepPublisherTest {

    @isTest
    static void publica_umPasso() {
        List<InvestigationStepPublisher.StepDef> steps =
            new List<InvestigationStepPublisher.StepDef>{
                new InvestigationStepPublisher.StepDef('summary', 'ok')
            };
        Test.startTest();
        System.enqueueJob(new InvestigationStepPublisher('inv-teste', steps, 0));
        Test.stopTest();
        System.assert(true, 'executou sem exceção');
    }
}
