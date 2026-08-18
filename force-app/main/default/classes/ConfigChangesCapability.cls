/**
 * Capacidade real: procura mudanças de configuração recentes (últimas 24h).
 *
 * Lê SetupAuditTrail (só leitura), o equivalente no Salesforce da pergunta do
 * incidente do proxy: "teve mudança recente?". Corresponde ao nó "Config recente".
 */
public with sharing class ConfigChangesCapability implements InvestigationCapability {

    private static final String NODE_LABEL = 'Config recente';

    public CapabilityResult run() {
        List<SetupAuditTrail> changes = [
            SELECT Action, Section, CreatedDate
            FROM SetupAuditTrail
            WHERE CreatedDate = LAST_N_DAYS:1
            ORDER BY CreatedDate DESC
            LIMIT 200
        ];

        if (!changes.isEmpty()) {
            SetupAuditTrail latest = changes[0];
            return new CapabilityResult(
                true,
                NODE_LABEL,
                changes.size() + ' mudança(s) de config nas últimas 24h; a mais recente: "' +
                    latest.Action + '".'
            );
        }

        return new CapabilityResult(
            false,
            NODE_LABEL,
            'Nenhuma mudança de config nas últimas 24h.'
        );
    }
}
