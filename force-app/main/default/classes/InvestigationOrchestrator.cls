/**
 * Orquestrador da investigação — o loop de raciocínio, guiado pela Claude.
 *
 * A cada passo (Queueable que se re-enfileira) o agente NARRA em primeira pessoa
 * o que está fazendo — pensando, decidindo (com o porquê), vasculhando, achando —
 * publicando eventos de narração, de nó do mapa, e de CÓDIGO (o código-fonte real
 * aparecendo na tela). É isso que torna o raciocínio visível ao vivo.
 *
 * O agente se vira: descobre as classes, abre o código real, avalia. Se algo estiver
 * fora do alcance (rede/proxy externo), ele para e reporta com honestidade — nunca
 * inventa uma causa.
 */
public with sharing class InvestigationOrchestrator implements Queueable, Database.AllowsCallouts {

    private static final Integer MAX_ITERATIONS = 8;

    // Classes internas do próprio agente — não são alvo de investigação.
    private static final Set<String> FRAMEWORK = new Set<String>{
        'ClaudeService', 'InvestigationOrchestrator', 'InvestigationController',
        'InvestigationCapability', 'CapabilityRegistry', 'CapabilityResult',
        'FailedJobsCapability', 'ConfigChangesCapability', 'InvestigationStepPublisher',
        'ToolingService'
    };

    private final String investigationId;
    private final String incident;
    private final List<String> findings;
    private final Integer iteration;

    public InvestigationOrchestrator(String investigationId, String incident,
                                     List<String> findings, Integer iteration) {
        this.investigationId = investigationId;
        this.incident = incident;
        this.findings = findings;
        this.iteration = iteration;
    }

    public static String start(String incident) {
        String investigationId = 'inv-' + String.valueOf(DateTime.now().getTime());
        System.enqueueJob(
            new InvestigationOrchestrator(investigationId, incident, new List<String>(), 0)
        );
        return investigationId;
    }

    public void execute(QueueableContext context) {
        if (iteration >= MAX_ITERATIONS) {
            publishNarration('pensando', 'Já investiguei bastante. Vou fechar com o que tenho.');
            publishSummary('Investigação encerrada por limite de passos, sem uma causa confirmada. Recomendo revisar manualmente os sinais já levantados.');
            return;
        }

        // Callout PRIMEIRO (antes de qualquer publish), pra evitar "uncommitted work".
        Map<String, Object> decision;
        try {
            decision = ClaudeService.decideNextStep(incident, findings);
        } catch (Exception e) {
            publishNarration('pensando', 'Tive um problema pra raciocinar sobre o próximo passo.');
            publishSummary('A investigação parou por uma falha operacional ao consultar o raciocínio: ' + e.getMessage() + '. Nenhuma causa foi confirmada.');
            return;
        }

        String acao = (String) decision.get('acao');
        String porque = (String) decision.get('porque');
        String capName = (String) decision.get('capacidade');
        String alvo = (String) decision.get('alvo');

        if (acao == 'concluir') {
            publishNarration('decisao', 'Já tenho o que preciso. Fechando o diagnóstico.');
            Object correcao = decision.get('correcao');
            if (correcao != null) {
                publishNarration('decisao', 'Tenho uma correção pra propor — vou pedir sua autorização antes de qualquer coisa.');
                publishFix(JSON.serialize(correcao));
            }
            publishSummary((String) decision.get('resumo'));
            return;
        }

        // Tolerante: às vezes a Claude põe a capacidade direto no 'acao'
        // (ex.: acao='testar_codigo') em vez de acao='rodar' + capacidade.
        if (String.isBlank(capName) && acao != 'rodar') {
            capName = acao;
        }

        if (String.isBlank(capName)) {
            publishSummary('Investigação encerrada: a decisão do raciocínio não foi reconhecida.');
            return;
        }

        // --- Ferramentas de código ---
        if (capName == 'listar_classes') {
            runListClasses(porque);
            return;
        }
        if (capName == 'inspecionar_codigo') {
            runInspectCode(alvo, porque);
            return;
        }
        if (capName == 'testar_codigo') {
            runTest((String) decision.get('codigo_teste'), porque);
            return;
        }
        if (capName == 'sondar_integracao') {
            runProbe((String) decision.get('endpoint'), porque);
            return;
        }

        // --- Sinais de infraestrutura (jobs/config) ---
        InvestigationCapability cap = CapabilityRegistry.resolve(capName);
        if (cap == null) {
            publishNarration('pensando', 'Pensei numa verificação que não tenho. Vou seguir com outra.');
            findings.add(capName + ': capacidade desconhecida, ignorada.');
            enqueueNext();
            return;
        }
        runSignal(cap, capName, porque);
    }

    // --- Handlers de cada tipo de passo ---

    private void runListClasses(String porque) {
        publishNarration('decisao', 'Vou ver quais classes existem pra investigar. ' + safe(porque));
        publishNarration('acao', 'Listando as classes do org…');
        List<String> names = readUnmanagedClassNames();
        String nomes = names.isEmpty() ? '(nenhuma)' : String.join(names, ', ');
        publishNarration('achado', 'Classes de negócio disponíveis: ' + nomes);
        findings.add('classes_disponiveis: ' + nomes);
        publishNarration('pensando', 'Deixa eu pensar qual delas olhar…');
        enqueueNext();
    }

    private void runInspectCode(String alvo, String porque) {
        publishNarration('decisao', 'Vou abrir o código de "' + safe(alvo) + '". ' + safe(porque));
        publishNarration('acao', 'Abrindo o código-fonte de ' + safe(alvo) + '…');
        String source = readClassSource(alvo);
        if (source == null) {
            publishNarration('descartado', 'Não encontrei o código de ' + safe(alvo) + '.');
            findings.add('inspecionar_codigo(' + alvo + '): classe não encontrada.');
        } else {
            publishCode(alvo, source);
            publishNarration('achado', 'Abri o código de ' + alvo + '. Vou analisar linha por linha.');
            findings.add('codigo(' + alvo + '):\n' + source);
        }
        publishNarration('pensando', 'Analisando o código…');
        enqueueNext();
    }

    private void runTest(String codigoTeste, String porque) {
        if (String.isBlank(codigoTeste)) {
            publishNarration('pensando', 'Quis testar mas não montei o código do teste. Vou seguir.');
            enqueueNext();
            return;
        }

        // Roda o teste PRIMEIRO (callout), antes de qualquer publish, pra evitar "uncommitted work".
        ToolingService.RunResult r;
        String erroExec;
        try {
            r = ToolingService.executeAnonymous(codigoTeste);
        } catch (Exception e) {
            erroExec = e.getMessage();
        }

        // Agora narra e mostra o teste + o console (o "screen-share").
        publishNarration('decisao', 'Vou escrever um teste pra provar isso. ' + safe(porque));
        publishTest('Verificação', codigoTeste);
        publishNarration('acao', 'Rodando o teste ao vivo…');

        if (erroExec != null) {
            publishTestResult('> Erro ao executar o teste:\n' + erroExec);
            publishNarration('achado', 'Não consegui rodar o teste: ' + erroExec);
            findings.add('teste: falha ao executar: ' + erroExec);
        } else if (r.compiled != true) {
            publishTestResult('> Compilação falhou:\n' + r.compileProblem);
            publishNarration('descartado', 'O teste não compilou.');
            findings.add('teste: erro de compilação: ' + r.compileProblem);
        } else if (r.success == true) {
            publishTestResult('> Executado.\n[OK] O teste passou — nenhuma exceção.');
            publishNarration('descartado', 'O teste passou — a hipótese não se confirmou aqui.');
            findings.add('teste passou (hipótese não confirmada).');
        } else {
            publishTestResult('> Executado.\n[FALHOU] ' + r.exceptionMessage);
            publishNarration('achado', 'O teste FALHOU — bug confirmado executando: ' + r.exceptionMessage);
            findings.add('teste FALHOU (bug confirmado): ' + r.exceptionMessage);
        }

        publishNarration('pensando', 'Analisando o resultado do teste…');
        enqueueNext();
    }

    private void runProbe(String endpoint, String porque) {
        if (String.isBlank(endpoint)) {
            publishNarration('pensando', 'Quis sondar uma integração mas não achei o endpoint. Vou seguir.');
            enqueueNext();
            return;
        }

        // Callout DIRETO (o Queueable já permite callout), PRIMEIRO — antes de qualquer
        // publish, pra evitar "uncommitted work". É GET (só leitura), nunca POST.
        Integer status;
        String excMsg;
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(endpoint);
            req.setMethod('GET');
            req.setTimeout(10000);
            HttpResponse res = new Http().send(req);
            status = res.getStatusCode();
        } catch (Exception e) {
            excMsg = e.getMessage();
        }

        // O que a sonda faz, mostrado na tela (só leitura).
        String probeShown =
            'HttpRequest req = new HttpRequest();\n' +
            'req.setEndpoint(\'' + endpoint + '\');\n' +
            'req.setMethod(\'GET\');   // sonda de leitura, nunca POST\n' +
            'new Http().send(req);';

        publishNarration('decisao', 'Vou sondar a conexão com "' + safe(endpoint) + '" ao vivo. ' + safe(porque));
        publishTest('Sonda de conexão', probeShown);
        publishNarration('acao', 'Disparando a sonda (GET, só leitura) ao vivo…');

        if (excMsg != null) {
            String local = localizeIntegration(excMsg);
            publishTestResult('> Sondado.\n[FALHOU] ' + excMsg);
            publishNarration('achado', 'A sonda falhou: ' + excMsg + ' — ' + local);
            findings.add('sonda(' + endpoint + '): FALHOU: ' + excMsg + ' | localizacao: ' + local);
        } else if (status == 200) {
            publishTestResult('> Sondado.\n[OK] Conexão respondeu 200 — o endpoint está acessível.');
            publishNarration('descartado', 'A conexão respondeu normal — o acesso ao endpoint está ok.');
            findings.add('sonda(' + endpoint + '): conexao OK (200).');
        } else {
            publishTestResult('> Sondado.\n[!] Conexão respondeu status ' + status + '.');
            publishNarration('achado', 'A conexão respondeu, mas com status ' + status + '.');
            findings.add('sonda(' + endpoint + '): respondeu status ' + status + '.');
        }

        publishNarration('pensando', 'Analisando o resultado da sonda…');
        enqueueNext();
    }

    // Traduz a exceção da sonda em ONDE está o problema (dentro do org vs fora).
    private static String localizeIntegration(String exc) {
        String m = (exc == null ? '' : exc).toLowerCase();
        if (m.contains('unauthorized endpoint') || m.contains('remote site')) {
            return 'é config DENTRO do org: o endpoint não está liberado (Remote Site Settings / Named Credential).';
        }
        if (m.contains('407') || m.contains('proxy')) {
            return 'é rede/proxy EXTERNO (407) — fora do meu alcance; precisa ser verificado na infraestrutura de rede.';
        }
        if (m.contains('timed out') || m.contains('timeout') || m.contains('read timed')) {
            return 'é timeout de rede — o endpoint externo pode estar fora do ar ou lento; fora do meu alcance.';
        }
        if (m.contains('unknownhost') || m.contains('unable to find') || m.contains('name resolution') || m.contains('dns')) {
            return 'é DNS/host inexistente — o endereço externo não resolve; fora do meu alcance.';
        }
        return 'não reconheci o tipo exato — precisa de análise manual da mensagem.';
    }

    private void runSignal(InvestigationCapability cap, String capName, String porque) {
        String nodeLabel = CapabilityRegistry.nodeLabelFor(capName);
        publishNarration('decisao', 'Vou verificar "' + nodeLabel + '". ' + safe(porque));
        publishStep('node_pulse', nodeLabel, null);
        publishNarration('acao', 'Vasculhando ' + nodeLabel + '…');

        CapabilityResult result = cap.run();

        if (result.suspect) {
            publishStep('node_hit', nodeLabel, result.message);
            publishNarration('achado', 'Achei algo: ' + result.message);
        } else {
            publishStep('node_clear', nodeLabel, result.message);
            publishNarration('descartado', 'Nada de errado aqui — descartado. ' + result.message);
        }
        findings.add(capName + ': ' + result.message);
        publishNarration('pensando', 'Deixa eu pensar no próximo passo…');
        enqueueNext();
    }

    // --- Leitura de código (SOQL nativo, sem callout) ---

    private static List<String> readUnmanagedClassNames() {
        List<String> names = new List<String>();
        for (ApexClass c : [SELECT Name FROM ApexClass WHERE NamespacePrefix = null ORDER BY Name]) {
            if (!FRAMEWORK.contains(c.Name) && !c.Name.endsWith('Test')) {
                names.add(c.Name);
            }
        }
        return names;
    }

    private static String readClassSource(String className) {
        if (String.isBlank(className)) {
            return null;
        }
        List<ApexClass> rows = [
            SELECT Body FROM ApexClass
            WHERE Name = :className AND NamespacePrefix = null
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0].Body;
    }

    // --- Publicação de eventos ---

    private void enqueueNext() {
        System.enqueueJob(
            new InvestigationOrchestrator(investigationId, incident, findings, iteration + 1)
        );
    }

    private void publishNarration(String kind, String text) {
        // Texto longo vai no Payload__c (Long Text); Message__c (Text 255) guarda só o "tipo".
        EventBus.publish(new Investigation_Step__e(
            Investigation_Id__c = investigationId,
            Step_Type__c        = 'narration',
            Message__c          = kind,
            Payload__c          = text
        ));
    }

    private void publishCode(String className, String source) {
        EventBus.publish(new Investigation_Step__e(
            Investigation_Id__c = investigationId,
            Step_Type__c        = 'code',
            Message__c          = className,
            Payload__c          = source
        ));
    }

    private void publishTest(String titulo, String codigoTeste) {
        EventBus.publish(new Investigation_Step__e(
            Investigation_Id__c = investigationId,
            Step_Type__c        = 'test',
            Message__c          = titulo,
            Payload__c          = codigoTeste
        ));
    }

    private void publishTestResult(String output) {
        EventBus.publish(new Investigation_Step__e(
            Investigation_Id__c = investigationId,
            Step_Type__c        = 'test_result',
            Message__c          = 'console',
            Payload__c          = output
        ));
    }

    private void publishStep(String stepType, String nodeLabel, String detail) {
        EventBus.publish(new Investigation_Step__e(
            Investigation_Id__c = investigationId,
            Step_Type__c        = stepType,
            Message__c          = nodeLabel,
            Payload__c          = detail
        ));
    }

    private void publishFix(String correcaoJson) {
        // Correção PROPOSTA (não aplicada). O humano decide na tela.
        EventBus.publish(new Investigation_Step__e(
            Investigation_Id__c = investigationId,
            Step_Type__c        = 'fix',
            Message__c          = 'fix',
            Payload__c          = correcaoJson
        ));
    }

    private void publishSummary(String resumo) {
        // Conclusão é um parágrafo -> vai no Payload__c (Long Text), nunca no Message__c (255).
        EventBus.publish(new Investigation_Step__e(
            Investigation_Id__c = investigationId,
            Step_Type__c        = 'summary',
            Message__c          = 'summary',
            Payload__c          = resumo
        ));
    }

    private static String safe(String s) {
        return s == null ? '' : s;
    }
}
