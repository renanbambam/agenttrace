/**
 * Agenda a Sentinela pra varrer o org automaticamente toda noite às 02:00.
 *   sf apex run --file scripts/apex/schedule-sentinel.apex -o agenttrace-org
 *
 * Pra cancelar: System.abortJob do CronTrigger (ou pelo Setup > Scheduled Jobs).
 * Na demo ao vivo, use o botão "Rodar varredura agora" na tela.
 */
String cron = '0 0 2 * * ?'; // todo dia às 02:00
Id jobId = System.schedule('AgentTrace Sentinela', cron, new SentinelScanner());
System.debug('Sentinela agendada (' + cron + ') jobId=' + jobId);
