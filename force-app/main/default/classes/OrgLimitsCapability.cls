/**
 * Capacidade real: verifica se algum limite do org está perto do teto (>= 80%).
 *
 * Só leitura (OrgLimits.getMap), sem efeito colateral. Pega o tipo de problema
 * "estava tudo bem e de repente parou" causado por governor/API limit estourando.
 */
public with sharing class OrgLimitsCapability implements InvestigationCapability {

    public CapabilityResult run() {
        List<String> altos = new List<String>();
        for (System.OrgLimit lim : OrgLimits.getMap().values()) {
            Integer max = lim.getLimit();
            Integer usado = lim.getValue();
            if (max != null && max > 0) {
                Double pct = ((Double) usado / (Double) max) * 100;
                if (pct >= 80) {
                    altos.add(lim.getName() + ': ' + usado + '/' + max + ' (' + Math.round(pct) + '%)');
                }
            }
        }
        if (altos.isEmpty()) {
            return new CapabilityResult(false, '', 'Nenhum limite do org perto do teto (todos abaixo de 80%).');
        }
        return new CapabilityResult(true, '', 'Limites perto do teto: ' + String.join(altos, '; '));
    }
}
