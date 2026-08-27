/**
 * Sentinela — a camada PROATIVA do AgentTrace ("sempre vigiando").
 *
 * Varre os sinais só-leitura do org (log de erro, jobs falhos, limites), REGISTRA
 * cada sinal suspeito como um alerta no histórico (Investigacao__c, Status='Alerta'),
 * e AUTO-INVESTIGA o mais crítico disparando o InvestigationOrchestrator (teto de
 * MAX_AUTO por varredura = guardrail de custo). Dispara por agendamento (Schedulable)
 * ou pelo botão "Rodar varredura agora" na tela. NUNCA aplica nada sozinho.
 */
public with sharing class SentinelScanner implements Schedulable {

    // Teto de auto-investigações por varredura (não sair torrando API num loop).
    private static final Integer MAX_AUTO = 1;

    public class Alerta implements Comparable {
        public String tipo;
        public String message;
        public Integer prio;
        public Alerta(String tipo, String message, Integer prio) {
            this.tipo = tipo; this.message = message; this.prio = prio;
        }
        public Integer compareTo(Object o) {
            return ((Alerta) o).prio - this.prio; // prioridade decrescente
        }
    }

    /** Ponto de entrada do agendamento. */
    public void execute(SchedulableContext sc) {
        runNow();
    }

    /** Roda a varredura agora (usado pelo agendamento e pelo botão da tela). */
    public static String runNow() {
        List<Alerta> alertas = new List<Alerta>();
        collect(alertas, 'Log de erro', new ErrorLogCapability().run(), 3);
        collect(alertas, 'Jobs assíncronos', new FailedJobsCapability().run(), 2);
        collect(alertas, 'Limites do org', new OrgLimitsCapability().run(), 1);

        if (alertas.isEmpty()) {
            return 'Varredura concluída: nenhum sinal suspeito. Org saudável. ✅';
        }
        alertas.sort(); // mais crítico primeiro

        // Registra TODOS os alertas no histórico.
        List<Investigacao__c> regs = new List<Investigacao__c>();
        for (Alerta a : alertas) {
            regs.add(new Investigacao__c(
                Incidente__c = 'Varredura automática detectou (' + a.tipo + '): ' + a.message,
                Status__c = 'Alerta',
                Passos__c = 0
            ));
        }
        insert regs;
        sendNotification(alertas.size(), alertas[0].tipo, regs[0].Id);

        // Auto-investiga o(s) mais crítico(s), até o teto.
        Integer autos = 0;
        for (Alerta a : alertas) {
            if (autos >= MAX_AUTO) { break; }
            InvestigationOrchestrator.start(
                'Varredura automática detectou (' + a.tipo + '): ' + a.message
                + '. Investigue a causa raiz.');
            autos++;
        }

        return alertas.size() + ' alerta(s) registrado(s) no histórico. '
            + 'Auto-investigando o mais crítico (' + alertas[0].tipo + ').';
    }

    private static void collect(List<Alerta> alertas, String tipo, CapabilityResult r, Integer prio) {
        if (r != null && r.suspect) {
            alertas.add(new Alerta(tipo, r.message, prio));
        }
    }

    // Notifica o usuário (sino do Salesforce) — nunca derruba a varredura se falhar.
    private static void sendNotification(Integer count, String topTipo, Id targetId) {
        try {
            List<CustomNotificationType> types = [
                SELECT Id FROM CustomNotificationType WHERE DeveloperName = 'AgentTrace_Alerta' LIMIT 1
            ];
            if (types.isEmpty()) { return; }
            Messaging.CustomNotification n = new Messaging.CustomNotification();
            n.setTitle('AgentTrace: ' + count + ' alerta(s) na varredura');
            n.setBody('Sinais suspeitos detectados (mais crítico: ' + topTipo + '). O agente está auto-investigando.');
            n.setNotificationTypeId(types[0].Id);
            n.setTargetId(targetId);
            n.send(new Set<String>{ UserInfo.getUserId() });
        } catch (Exception e) {
            // notificação é acessório; não interrompe a varredura
        }
    }
}
