/**
 * Orquestrador da investigação — o loop de raciocínio com TOOL_USE NATIVO.
 *
 * Roda numa transação só (sem encadear Queueable — o Dev Edition limita a cadeia a 5).
 * Usa o function calling da Anthropic: mantém um array de MENSAGENS, a Claude escolhe
 * uma FERRAMENTA (tool_use), o Apex executa e devolve o resultado como TOOL_RESULT, e o
 * loop segue até a Claude chamar a ferramenta "concluir" (ou "perguntar"). Os eventos
 * (Investigation_Step__e, PublishImmediately) transmitem cada passo ao vivo pra tela.
 */
public with sharing class InvestigationOrchestrator implements Queueable, Database.AllowsCallouts {

    private static final Integer MAX_ITERATIONS = 8;

    private static final List<String> PENSANDO = new List<String>{
        'Cruzando o que já descobri pra decidir o próximo passo…',
        'Formulando a próxima hipótese com base nas evidências…',
        'Decidindo onde vasculhar em seguida…',
        'Conectando os pontos entre o que já vi…',
        'Pesando qual evidência ainda falta…'
    };

    private static final Set<String> FRAMEWORK = new Set<String>{
        'ClaudeService', 'InvestigationOrchestrator', 'InvestigationController',
        'InvestigationCapability', 'CapabilityRegistry', 'CapabilityResult',
        'FailedJobsCapability', 'ConfigChangesCapability', 'InvestigationStepPublisher',
        'ToolingService', 'ErrorLogCapability', 'FixValidator',
        'OrgLimitsCapability', 'AutomationsCapability', 'AgentEval', 'CodeDeployer',
        'SentinelScanner'
    };

    private static final Set<String> PII_TOKENS = new Set<String>{
        'email', 'phone', 'mobilephone', 'homephone', 'ssn', 'cpf', 'cnpj', 'rg',
        'birthdate', 'passport', 'fax', 'mailingstreet', 'personemail', 'personmobilephone'
    };

    private final String investigationId;
    private final String incident;
    private final Set<String> usedCaps = new Set<String>();
    private Long startMs;

    public InvestigationOrchestrator(String investigationId, String incident) {
        this.investigationId = investigationId;
        this.incident = incident;
    }

    public static String start(String incident) {
        String investigationId = 'inv-' + String.valueOf(DateTime.now().getTime());
        System.enqueueJob(new InvestigationOrchestrator(investigationId, incident));
        return investigationId;
    }

    public void execute(QueueableContext context) {
        startMs = DateTime.now().getTime();
        ClaudeService.resetUsage();

        // A conversa começa com o incidente; cresce com tool_use / tool_result.
        List<Object> messages = new List<Object>{
            new Map<String, Object>{ 'role' => 'user', 'content' => incident }
        };

        for (Integer iter = 0; iter < MAX_ITERATIONS; iter++) {
            publishThinking(iter == 0
                ? 'Recebi o incidente. Analisando por onde começar…'
                : PENSANDO[Math.mod(iter, PENSANDO.size())]);

            Map<String, Object> r;
            try {
                r = ClaudeService.reason(messages);
            } catch (Exception e) {
                publishNarration('pensando', 'Tive um problema pra raciocinar sobre o próximo passo.');
                publishSummary('A investigação parou por uma falha operacional: ' + e.getMessage() + '.');
                return;
            }

            // Guarda o turno do assistente na conversa.
            messages.add(new Map<String, Object>{ 'role' => 'assistant', 'content' => r.get('assistantContent') });

            String toolName = (String) r.get('toolName');

            // Sem ferramenta = a Claude respondeu só texto -> trata como conclusão.
            if (String.isBlank(toolName)) {
                String txt = (String) r.get('text');
                publishSummary(String.isBlank(txt) ? 'Investigação encerrada sem conclusão.' : txt);
                saveInvestigation(txt, null, 'inconclusivo', iter, 'Concluída');
                return;
            }

            Map<String, Object> input = (Map<String, Object>) r.get('toolInput');
            if (input == null) { input = new Map<String, Object>(); }
            String porque = (String) input.get('porque');

            if (toolName == 'concluir') {
                handleConclude(input, iter);
                return;
            }
            if (toolName == 'perguntar') {
                String pergunta = (String) input.get('pergunta');
                publishQuestion(String.isBlank(pergunta) ? 'Pode detalhar mais o incidente?' : pergunta);
                return;
            }

            usedCaps.add(toolName);
            publishTool(toolName);

            String observation;
            try {
                observation = runToolCapability(toolName, input, porque);
            } catch (Exception e) {
                observation = 'Erro ao executar a capacidade: ' + e.getMessage();
                publishNarration('pensando', observation);
            }

            // Devolve o resultado da ferramenta pra Claude (tool_result).
            messages.add(new Map<String, Object>{
                'role' => 'user',
                'content' => new List<Object>{
                    new Map<String, Object>{
                        'type' => 'tool_result',
                        'tool_use_id' => r.get('toolUseId'),
                        'content' => observation
                    }
                }
            });
        }

        publishNarration('pensando', 'Já investiguei bastante. Vou fechar com o que tenho.');
        String semCausa = 'Investigação encerrada por limite de passos, sem uma causa 100% confirmada.';
        publishSummary(semCausa);
        saveInvestigation(semCausa, null, 'inconclusivo', MAX_ITERATIONS, 'Inconclusiva');
    }

    // Fecha a investigação com os campos estruturados da ferramenta "concluir".
    private void handleConclude(Map<String, Object> input, Integer iter) {
        publishNarration('decisao', 'Já tenho o que preciso. Fechando o diagnóstico.');
        String resumo = (String) input.get('resumo');
        String area = (String) input.get('area');
        String impacto = (String) input.get('impacto_negocio');
        Object correcao = input.get('correcao');
        if (correcao instanceof Map<String, Object> && !((Map<String, Object>) correcao).isEmpty()) {
            publishNarration('decisao', 'Tenho uma correção pra propor — vou pedir sua autorização antes de qualquer coisa.');
            publishFix(JSON.serialize(correcao));
        }
        if (String.isNotBlank(impacto)) { publishImpact(impacto); }
        publishCost();
        publishSummary(resumo);
        String status = (area == 'externo') ? 'Fora do alcance' : 'Concluída';
        saveInvestigation(resumo, impacto, area, iter, status);
    }

    // Despacha a ferramenta pra capacidade e devolve a OBSERVAÇÃO (vira o tool_result).
    private String runToolCapability(String name, Map<String, Object> input, String porque) {
        if (name == 'listar_classes') { return runListClasses(porque); }
        if (name == 'inspecionar_codigo') { return runInspectCode((String) input.get('alvo'), porque); }
        if (name == 'testar_codigo') { return runTest((String) input.get('codigo_teste'), porque); }
        if (name == 'sondar_integracao') { return runProbe((String) input.get('endpoint'), porque); }
        if (name == 'buscar_no_codigo') { return runBuscarCodigo((String) input.get('termo'), porque); }
        if (name == 'schema_objeto') { return runSchema((String) input.get('objeto'), porque); }
        if (name == 'consultar_dados') { return runConsultarDados((String) input.get('soql'), porque); }
        if (name == 'ler_debug_logs') { return runDebugLogs(porque); }

        InvestigationCapability cap = CapabilityRegistry.resolve(name);
        if (cap == null) { return 'Capacidade desconhecida: ' + name + '.'; }
        return runSignal(cap, name, porque);
    }

    // --- Handlers: publicam ao vivo E devolvem a observação pra Claude ---

    private String runListClasses(String porque) {
        publishNarration('decisao', 'Vou ver quais classes existem pra investigar. ' + safe(porque));
        publishNarration('acao', 'Listando as classes do org…');
        List<String> names = readUnmanagedClassNames();
        String nomes = names.isEmpty() ? '(nenhuma)' : String.join(names, ', ');
        publishNarration('achado', 'Classes de negócio disponíveis: ' + nomes);
        return 'Classes de negócio disponíveis: ' + nomes;
    }

    private String runInspectCode(String alvo, String porque) {
        publishNarration('decisao', 'Vou abrir o código de "' + safe(alvo) + '". ' + safe(porque));
        publishNarration('acao', 'Abrindo o código-fonte de ' + safe(alvo) + '…');
        String source = readClassSource(alvo);
        if (source == null) {
            publishNarration('descartado', 'Não encontrei o código de ' + safe(alvo) + '.');
            return 'Classe ' + alvo + ' não encontrada.';
        }
        publishCode(alvo, source);
        publishNarration('achado', 'Abri o código de ' + alvo + '. Vou analisar linha por linha.');
        return 'Código de ' + alvo + ':\n' + source;
    }

    private String runTest(String codigoTeste, String porque) {
        if (String.isBlank(codigoTeste)) { return 'Nenhum código de teste foi fornecido.'; }

        ToolingService.RunResult r;
        String erroExec;
        try {
            r = ToolingService.executeAnonymous(codigoTeste);
        } catch (Exception e) {
            erroExec = e.getMessage();
        }

        publishNarration('decisao', 'Vou escrever um teste pra provar isso. ' + safe(porque));
        publishTest('Verificação', codigoTeste);
        publishNarration('acao', 'Rodando o teste ao vivo…');

        if (erroExec != null) {
            publishTestResult('> Erro ao executar o teste:\n' + erroExec);
            publishNarration('achado', 'Não consegui rodar o teste: ' + erroExec);
            return 'Falha ao executar o teste: ' + erroExec;
        }
        if (r.compiled != true) {
            publishTestResult('> Compilação falhou:\n' + r.compileProblem);
            publishNarration('descartado', 'O teste não compilou.');
            return 'Erro de compilação: ' + r.compileProblem;
        }
        if (r.success == true) {
            publishTestResult('> Executado.\n[OK] O teste passou — nenhuma exceção.');
            publishNarration('descartado', 'O teste passou — a hipótese não se confirmou aqui.');
            return 'O teste PASSOU (hipótese não confirmada).';
        }
        publishTestResult('> Executado.\n[FALHOU] ' + r.exceptionMessage);
        publishNarration('achado', 'O teste FALHOU — bug confirmado executando: ' + r.exceptionMessage);
        return 'O teste FALHOU (bug confirmado): ' + r.exceptionMessage;
    }

    private String runProbe(String endpoint, String porque) {
        if (String.isBlank(endpoint)) { return 'Nenhum endpoint foi fornecido.'; }

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
            return 'A sonda FALHOU: ' + excMsg + ' | localização: ' + local;
        }
        if (status == 200) {
            publishTestResult('> Sondado.\n[OK] Conexão respondeu 200 — o endpoint está acessível.');
            publishNarration('descartado', 'A conexão respondeu normal — o acesso ao endpoint está ok.');
            return 'A conexão respondeu 200 (endpoint acessível).';
        }
        publishTestResult('> Sondado.\n[!] Conexão respondeu status ' + status + '.');
        publishNarration('achado', 'A conexão respondeu, mas com status ' + status + '.');
        return 'A conexão respondeu status ' + status + '.';
    }

    @TestVisible
    private static String localizeIntegration(String exc) {
        String m = (exc == null ? '' : exc).toLowerCase();
        if (m.contains('unauthorized endpoint') || m.contains('remote site')) {
            return 'é config DENTRO do org: o endpoint não está liberado (Remote Site Settings / Named Credential).';
        }
        if (m.contains('407') || m.contains('proxy')) {
            return 'é rede/proxy EXTERNO (407) — fora do meu alcance; verificar a infraestrutura de rede.';
        }
        if (m.contains('timed out') || m.contains('timeout') || m.contains('read timed')) {
            return 'é timeout de rede — o endpoint externo pode estar fora do ar ou lento; fora do meu alcance.';
        }
        if (m.contains('unknownhost') || m.contains('unable to find') || m.contains('name resolution') || m.contains('dns')) {
            return 'é DNS/host inexistente — o endereço externo não resolve; fora do meu alcance.';
        }
        return 'não reconheci o tipo exato — precisa de análise manual da mensagem.';
    }

    private String runBuscarCodigo(String termo, String porque) {
        if (String.isBlank(termo)) { return 'Nenhum termo de busca foi fornecido.'; }
        publishNarration('decisao', 'Vou procurar "' + termo + '" em todo o código. ' + safe(porque));
        publishNarration('acao', 'Buscando "' + termo + '" nas classes…');

        String alvo = termo.toLowerCase();
        List<String> hits = new List<String>();
        for (ApexClass c : [SELECT Name, Body FROM ApexClass WHERE NamespacePrefix = null]) {
            if (FRAMEWORK.contains(c.Name) || c.Name.endsWith('Test') || c.Body == null) { continue; }
            String[] linhas = c.Body.split('\n');
            for (Integer i = 0; i < linhas.size(); i++) {
                if (linhas[i].toLowerCase().contains(alvo)) {
                    hits.add(c.Name + ':' + (i + 1) + '  ' + linhas[i].trim());
                }
            }
        }
        if (hits.isEmpty()) {
            publishNarration('descartado', 'Não achei "' + termo + '" em nenhuma classe de negócio.');
            return 'Nenhuma ocorrência de "' + termo + '".';
        }
        List<String> mostra = new List<String>();
        for (Integer i = 0; i < Math.min(12, hits.size()); i++) { mostra.add(hits[i]); }
        publishNarration('achado', hits.size() + ' ocorrência(s) de "' + termo + '": ' + String.join(mostra, ' | '));
        return hits.size() + ' ocorrência(s) de "' + termo + '": ' + String.join(hits, ' | ');
    }

    private String runSchema(String objeto, String porque) {
        if (String.isBlank(objeto)) { return 'Nenhum objeto foi fornecido.'; }
        publishNarration('decisao', 'Vou ver os campos de "' + objeto + '". ' + safe(porque));
        Schema.SObjectType t = Schema.getGlobalDescribe().get(objeto);
        if (t == null) {
            publishNarration('descartado', 'O objeto "' + objeto + '" não existe neste org.');
            return 'O objeto ' + objeto + ' não existe.';
        }
        List<String> campos = new List<String>();
        for (Schema.SObjectField f : t.getDescribe().fields.getMap().values()) {
            Schema.DescribeFieldResult d = f.getDescribe();
            campos.add(d.getName() + ' (' + d.getType() + ')');
        }
        publishNarration('achado', objeto + ' tem ' + campos.size() + ' campos: ' + String.join(campos, ', '));
        return objeto + ' tem ' + campos.size() + ' campos: ' + String.join(campos, ', ');
    }

    private String runConsultarDados(String soql, String porque) {
        if (String.isBlank(soql)) { return 'Nenhuma query foi fornecida.'; }
        String q = soql.trim();
        String qLower = q.toLowerCase();
        if (!qLower.startsWith('select')) {
            publishNarration('descartado', 'Recusei uma consulta que não era SELECT — só leitura é permitida.');
            return 'Recusado: só SELECT (leitura) é permitido.';
        }
        for (String pii : PII_TOKENS) {
            if (qLower.contains(pii)) {
                publishNarration('descartado',
                    'Recusei por PRIVACIDADE: a consulta tocaria em dado pessoal ("' + pii + '"). ' +
                    'Eu investigo fundo, mas não acesso dados de pessoas — uso contagem/agregado no lugar.');
                return 'RECUSADO por privacidade: a query toca em PII ("' + pii + '"). Use COUNT()/agregado.';
            }
        }

        publishNarration('decisao', 'Vou consultar os dados reais pra confirmar. ' + safe(porque));
        publishTest('Consulta (SOQL)', q);
        publishNarration('acao', 'Rodando a consulta ao vivo…');

        Boolean isCount = qLower.replaceAll('\\s+', '').startsWith('selectcount()');
        try {
            if (isCount) {
                Integer total = Database.countQuery(q);
                publishTestResult('> Resultado: ' + total + ' registro(s).');
                publishNarration('achado', 'A consulta contou ' + total + ' registro(s) nos dados reais.');
                return 'COUNT = ' + total + ' registro(s).';
            }
            List<SObject> rows = Database.query(q);
            String amostra = '(sem registros)';
            if (!rows.isEmpty()) {
                List<SObject> primeiros = new List<SObject>();
                for (Integer i = 0; i < Math.min(3, rows.size()); i++) { primeiros.add(rows[i]); }
                amostra = JSON.serialize(primeiros);
                if (amostra.length() > 1500) { amostra = amostra.substring(0, 1500) + '…'; }
            }
            publishTestResult('> ' + rows.size() + ' registro(s).\nAmostra: ' + amostra);
            publishNarration('achado', 'A consulta retornou ' + rows.size() + ' registro(s).');
            return rows.size() + ' registro(s). Amostra: ' + amostra;
        } catch (Exception e) {
            publishTestResult('> Erro na consulta:\n' + e.getMessage());
            publishNarration('descartado', 'A consulta falhou: ' + e.getMessage());
            return 'Erro na consulta: ' + e.getMessage();
        }
    }

    private String runDebugLogs(String porque) {
        publishNarration('decisao', 'Vou vasculhar os logs de debug do runtime. ' + safe(porque));
        publishNarration('acao', 'Lendo os logs de execução recentes…');

        List<ApexLog> logs;
        try {
            logs = [
                SELECT Id, Operation, Status, DurationMilliseconds, LogLength, StartTime
                FROM ApexLog ORDER BY StartTime DESC LIMIT 5
            ];
        } catch (Exception e) {
            publishNarration('descartado', 'Não consegui ler os logs de debug: ' + e.getMessage());
            return 'Erro de acesso aos logs: ' + e.getMessage();
        }
        if (logs.isEmpty()) {
            publishNarration('descartado', 'Nenhum log de debug recente — a trace flag pode estar desligada.');
            return 'Nenhum log de debug recente (trace flag pode estar desligada).';
        }

        ApexLog alvo = logs[0];
        String corpo;
        try {
            corpo = ToolingService.getLogBody(alvo.Id);
        } catch (Exception e) {
            corpo = '(não consegui baixar o corpo do log: ' + e.getMessage() + ')';
        }

        List<String> meta = new List<String>();
        for (ApexLog l : logs) {
            meta.add(l.Operation + ' [' + l.Status + '] ' + l.DurationMilliseconds + 'ms');
        }
        String corpoMostra = (corpo != null && corpo.length() > 4000)
            ? corpo.substring(0, 4000) + '\n…(truncado)' : corpo;

        publishTest('Debug log: ' + alvo.Operation, corpoMostra);
        publishNarration('achado', logs.size() + ' log(s) recente(s): ' + String.join(meta, ' | '));
        String trecho = (corpo != null && corpo.length() > 800) ? corpo.substring(0, 800) : corpo;
        return 'Logs recentes: ' + String.join(meta, ' | ') + '. Trecho do mais recente: ' + trecho;
    }

    private String runSignal(InvestigationCapability cap, String capName, String porque) {
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
        return result.message;
    }

    // --- Leitura de código (SOQL nativo) ---

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
        if (String.isBlank(className)) { return null; }
        List<ApexClass> rows = [
            SELECT Body FROM ApexClass WHERE Name = :className AND NamespacePrefix = null LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0].Body;
    }

    // --- Persistência (registro da investigação) ---

    private void saveInvestigation(String resumo, String impacto, String area, Integer steps, String status) {
        try {
            Long dur = (startMs == null) ? 0 : (DateTime.now().getTime() - startMs);
            insert new Investigacao__c(
                Incidente__c       = trunc(incident, 32000),
                Conclusao__c       = trunc(resumo, 32000),
                Impacto_Negocio__c = trunc(impacto, 32000),
                Area__c            = area,
                Capacidades__c     = trunc(String.join(new List<String>(usedCaps), ', '), 255),
                Passos__c          = steps,
                Duracao_Seg__c     = Math.round(dur / 1000.0),
                Tokens__c          = ClaudeService.getTokens(),
                Custo_USD__c       = ClaudeService.getCostUsd().setScale(4),
                Status__c          = status
            );
        } catch (Exception e) {
            publishNarration('pensando', 'Não consegui registrar a investigação no histórico: ' + e.getMessage());
        }
    }

    private static String trunc(String s, Integer n) {
        if (s == null) { return null; }
        return s.length() > n ? s.substring(0, n) : s;
    }

    // --- Publicação de eventos (PublishImmediately -> chega ao vivo) ---

    private void publishTool(String capName) {
        EventBus.publish(new Investigation_Step__e(
            Investigation_Id__c = investigationId, Step_Type__c = 'tool',
            Message__c = capName, Payload__c = null));
    }

    private void publishQuestion(String pergunta) {
        publishNarration('pensando', 'O incidente está vago pra eu ir direto ao ponto. Vou perguntar antes de adivinhar.');
        EventBus.publish(new Investigation_Step__e(
            Investigation_Id__c = investigationId, Step_Type__c = 'question',
            Message__c = 'question', Payload__c = pergunta));
    }

    private void publishCost() {
        Integer tok = ClaudeService.getTokens();
        Decimal usd = ClaudeService.getCostUsd().setScale(4);
        Long dur = (startMs == null) ? 0 : (DateTime.now().getTime() - startMs);
        String txt = tok + ' tokens · ~$' + usd + ' · ' + Math.round(dur / 1000.0) + 's';
        EventBus.publish(new Investigation_Step__e(
            Investigation_Id__c = investigationId, Step_Type__c = 'cost',
            Message__c = 'cost', Payload__c = txt));
    }

    private void publishImpact(String texto) {
        EventBus.publish(new Investigation_Step__e(
            Investigation_Id__c = investigationId, Step_Type__c = 'impact',
            Message__c = 'impact', Payload__c = texto));
    }

    private void publishThinking(String texto) {
        EventBus.publish(new Investigation_Step__e(
            Investigation_Id__c = investigationId, Step_Type__c = 'thinking',
            Message__c = 'thinking', Payload__c = texto));
    }

    private void publishNarration(String kind, String text) {
        EventBus.publish(new Investigation_Step__e(
            Investigation_Id__c = investigationId, Step_Type__c = 'narration',
            Message__c = kind, Payload__c = text));
    }

    private void publishCode(String className, String source) {
        EventBus.publish(new Investigation_Step__e(
            Investigation_Id__c = investigationId, Step_Type__c = 'code',
            Message__c = className, Payload__c = source));
    }

    private void publishTest(String titulo, String codigoTeste) {
        EventBus.publish(new Investigation_Step__e(
            Investigation_Id__c = investigationId, Step_Type__c = 'test',
            Message__c = titulo, Payload__c = codigoTeste));
    }

    private void publishTestResult(String output) {
        EventBus.publish(new Investigation_Step__e(
            Investigation_Id__c = investigationId, Step_Type__c = 'test_result',
            Message__c = 'console', Payload__c = output));
    }

    private void publishStep(String stepType, String nodeLabel, String detail) {
        EventBus.publish(new Investigation_Step__e(
            Investigation_Id__c = investigationId, Step_Type__c = stepType,
            Message__c = nodeLabel, Payload__c = detail));
    }

    private void publishFix(String correcaoJson) {
        EventBus.publish(new Investigation_Step__e(
            Investigation_Id__c = investigationId, Step_Type__c = 'fix',
            Message__c = 'fix', Payload__c = correcaoJson));
    }

    private void publishSummary(String resumo) {
        EventBus.publish(new Investigation_Step__e(
            Investigation_Id__c = investigationId, Step_Type__c = 'summary',
            Message__c = 'summary', Payload__c = resumo));
    }

    private static String safe(String s) {
        return s == null ? '' : s;
    }
}
