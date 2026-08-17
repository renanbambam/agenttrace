/**
 * Capacidade real: procura jobs assíncronos que falharam nas últimas 24h.
 *
 * Só leitura (SOQL em AsyncApexJob), sem efeito colateral. Corresponde ao nó
 * "Jobs assíncronos" do mapa.
 */
public with sharing class FailedJobsCapability implements InvestigationCapability {

    private static final String NODE_LABEL = 'Jobs assíncronos';

    public CapabilityResult run() {
        Integer failures = [
            SELECT COUNT()
            FROM AsyncApexJob
            WHERE Status = 'Failed'
            AND CreatedDate = LAST_N_DAYS:1
        ];

        if (failures > 0) {
            return new CapabilityResult(
                true,
                NODE_LABEL,
                failures + ' job(s) assíncrono(s) falharam nas últimas 24h.'
            );
        }

        return new CapabilityResult(
            false,
            NODE_LABEL,
            'Nenhum job assíncrono falhou nas últimas 24h.'
        );
    }
}
