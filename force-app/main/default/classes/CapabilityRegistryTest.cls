/**
 * Testes do registro de capacidades: lista, resolve (tipos certos) e rótulo do nó.
 */
@isTest
private class CapabilityRegistryTest {

    @isTest
    static void available_naoVazia() {
        System.assert(!CapabilityRegistry.available().isEmpty());
    }

    @isTest
    static void resolve_tiposCertos() {
        System.assert(CapabilityRegistry.resolve('jobs_falha') instanceof FailedJobsCapability);
        System.assert(CapabilityRegistry.resolve('config_recente') instanceof ConfigChangesCapability);
        System.assert(CapabilityRegistry.resolve('log_erro') instanceof ErrorLogCapability);
        System.assertEquals(null, CapabilityRegistry.resolve('inexistente'));
    }

    @isTest
    static void nodeLabel_encontraEFallback() {
        System.assertEquals('Log de erro', CapabilityRegistry.nodeLabelFor('log_erro'));
        System.assertEquals('desconhecida', CapabilityRegistry.nodeLabelFor('desconhecida'));
    }
}
