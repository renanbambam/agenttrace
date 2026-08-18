/**
 * Registro das capacidades de investigação disponíveis.
 *
 * Serve a três papéis:
 *  - available(): descreve as capacidades pra Claude escolher (vai no prompt).
 *  - resolve(name): devolve a instância pra o Apex rodar a capacidade escolhida.
 *  - nodeLabelFor(name): o rótulo do nó no mapa (pra pulsar antes de rodar).
 *
 * Adicionar uma capacidade nova = uma entrada aqui + a classe que implementa
 * InvestigationCapability. As existentes não são tocadas.
 */
public with sharing class CapabilityRegistry {

    public class CapabilityInfo {
        public String name;
        public String nodeLabel;
        public String description;
        public CapabilityInfo(String name, String nodeLabel, String description) {
            this.name = name;
            this.nodeLabel = nodeLabel;
            this.description = description;
        }
    }

    public static List<CapabilityInfo> available() {
        return new List<CapabilityInfo>{
            new CapabilityInfo(
                'jobs_falha',
                'Jobs assíncronos',
                'Verifica se jobs assíncronos (Batch/Queueable) falharam nas últimas 24h. ' +
                'Use para incidentes sobre processos noturnos ou em lote que pararam de rodar.'
            ),
            new CapabilityInfo(
                'config_recente',
                'Config recente',
                'Verifica mudanças de configuração recentes (SetupAuditTrail) nas últimas 24h. ' +
                'Use quando o problema começou depois de alguém mexer em permissão ou configuração.'
            ),
            new CapabilityInfo(
                'log_erro',
                'Log de erro',
                'Lê os erros já REGISTRADOS no log da aplicação (objeto Log_Erro__c, últimos 7 dias). ' +
                'Use quando algo "parou" ou "deu erro" e você quer ver o que foi registrado antes de ' +
                'agir — inclusive falhas de integração. Se os logs mostram rede/proxy externo (407, ' +
                'timeout, DNS) de forma recorrente, isso é FORA do seu alcance. Não precisa de alvo.'
            ),
            new CapabilityInfo(
                'listar_classes',
                '',
                'Lista as classes Apex do org (código de negócio) que podem ser inspecionadas. ' +
                'Use quando o incidente sugere erro de cálculo, lógica ou comportamento de código ' +
                'e você precisa descobrir QUAL classe olhar. Não precisa de alvo.'
            ),
            new CapabilityInfo(
                'inspecionar_codigo',
                '',
                'Abre e mostra o código-fonte real de uma classe. Requer o campo "alvo" com o nome ' +
                'exato da classe. Depois de ver o código você pode identificar bugs, avaliar se está ' +
                'bem escrito e recomendar melhorias. Descubra o nome antes com listar_classes.'
            ),
            new CapabilityInfo(
                'testar_codigo',
                '',
                'Escreve e RODA ao vivo uma verificação (Apex anônimo) contra um método, pra PROVAR ' +
                'um bug executando. Requer o campo "codigo_teste" com o Apex a rodar. Use depois de ' +
                'inspecionar o código, quando quiser confirmar a hipótese na prática.'
            ),
            new CapabilityInfo(
                'sondar_integracao',
                'Integração externa',
                'Dispara uma SONDA de conexão AO VIVO (callout GET, só leitura) contra o endpoint de ' +
                'uma integração e lê a exceção REAL. Requer o campo "endpoint" com a URL exata (você ' +
                'a descobre inspecionando a classe de integração). Use para incidentes de integração/' +
                'callout falhando. O resultado te diz se é config no org (ex.: "Unauthorized endpoint" ' +
                '= endpoint não liberado em Remote Site) ou falha de rede/proxy externo (407, timeout, ' +
                'DNS) — que está FORA do seu alcance e você deve apontar com honestidade.'
            )
        };
    }

    public static InvestigationCapability resolve(String name) {
        if (name == 'jobs_falha') {
            return new FailedJobsCapability();
        }
        if (name == 'config_recente') {
            return new ConfigChangesCapability();
        }
        if (name == 'log_erro') {
            return new ErrorLogCapability();
        }
        return null;
    }

    public static String nodeLabelFor(String name) {
        for (CapabilityInfo c : available()) {
            if (c.name == name) {
                return c.nodeLabel;
            }
        }
        return name;
    }
}
