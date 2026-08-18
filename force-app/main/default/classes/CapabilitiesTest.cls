/**
 * Testes das capacidades de sinal (só leitura). ErrorLogCapability é testada com
 * dado inserido (acha e não-acha); FailedJobs/ConfigChanges executam sem dado de teste
 * (no contexto de teste não há jobs falhos nem trilha de auditoria) — cobrem o caminho.
 */
@isTest
private class CapabilitiesTest {

    @isTest
    static void errorLog_achaRegistro() {
        insert new Log_Erro__c(Origem__c = 'X', Nivel__c = 'ERROR', Mensagem__c = 'falha registrada');
        Test.startTest();
        CapabilityResult r = new ErrorLogCapability().run();
        Test.stopTest();
        System.assertEquals(true, r.suspect);
        System.assertEquals('Log de erro', r.nodeLabel);
    }

    @isTest
    static void errorLog_semRegistro() {
        Test.startTest();
        CapabilityResult r = new ErrorLogCapability().run();
        Test.stopTest();
        System.assertEquals(false, r.suspect);
    }

    @isTest
    static void failedJobs_executa() {
        Test.startTest();
        CapabilityResult r = new FailedJobsCapability().run();
        Test.stopTest();
        System.assertNotEquals(null, r.message);
    }

    @isTest
    static void configChanges_executa() {
        Test.startTest();
        CapabilityResult r = new ConfigChangesCapability().run();
        Test.stopTest();
        System.assertNotEquals(null, r.message);
    }
}
