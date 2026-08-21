/**
 * Orquestrador da investigação — o loop de raciocínio, guiado pela Claude.
 *
 * O loop RODA INTEIRO NUMA TRANSAÇÃO SÓ (um Queueable, um for). Antes era um
 * Queueable que se re-enfileirava a cada passo, mas o Developer Edition limita a
 * cadeia de Queueables a 5 níveis ("Maximum stack depth") — investigação funda
 * quebrava no 6º passo. Rodando o loop numa transação só: sem limite de pilha,
 * sem atraso entre passos (bem mais rápido), e os eventos continuam AO VIVO porque
 * o Investigation_Step__e é PublishImmediately (entregue na hora, não no commit).
 *
 * A cada passo o agente NARRA em primeira pessoa (pensando, decidindo com o porquê,
 * vasculhando, achando) e mostra artefatos reais (código, consulta, console). Se algo
 * estiver fora do alcance (rede/proxy externo), ele para e reporta com honestidade.
 */
public with sharing class InvestigationOrchestrator implements Queueable, Database.AllowsCallouts {

    // Passos máximos numa investigação. Fica dentro do orçamento de callout (120s/transação).
    private static final Integer MAX_ITERATIONS = 8;

    // Frases de "pensando" entre passos (variadas, pra o status não ficar repetitivo).
    private static final List<String> PENSANDO = new List<String>{
        'Cruzando o que já descobri pra decidir o próximo passo…',
        'Formulando a próxima hipótese com base nas evidências…',
        'Decidindo onde vasculhar em seguida…',
        'Conectando os pontos entre o que já vi…',
        'Pesando qual evidência ainda falta…'
    };

    // Classes internas do próprio agente — não são alvo de investigação.
    private static final Set<String> FRAMEWORK = new Set<String>{
        'ClaudeService', 'InvestigationOrchestrator', 'InvestigationController',
        'InvestigationCapability', 'CapabilityRegistry', 'CapabilityResult',
        'FailedJobsCapability', 'ConfigChangesCapability', 'InvestigationStepPublisher',
        'ToolingService', 'ErrorLogCapability', 'FixValidator',
        'OrgLimitsCapability', 'AutomationsCapability', 'AgentEval'
    };

    // Tokens de dado pessoal (PII) que a consulta de dados NUNCA pode tocar.
    private static final Set<String> PII_TOKENS = new Set<String>{
        'email', 'phone', 'mobilephone', 'homephone', 'ssn', 'cpf', 'cnpj', 'rg',
        'birthdate', 'passport', 'fax', 'mailingstreet', 'personemail', 'personmobilephone'
    };

    private final String investigationId;
    private final String incident;
    private final List<String> findings = new List<String>();
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
        for (Integer iter = 0; iter < MAX_ITERATIONS; iter++) {
            // Feedback IMEDIATO do que ele está pensando, ANTES da Claude responder.
            publishThinking(iter == 0
                ? 'Recebi o incidente. Analisando por onde começar…'
                : PENSANDO[Math.mod(iter, PENSANDO.size())]);

            Map<String, Object> decision;
            try {
                decision = ClaudeService.decideNextStep(incident, findings);
            } catch (Exception e) {
                publishNarration('pensando', 'Tive um problema pra raciocinar sobre o próximo passo.');
                publishSummary('A investigação parou por uma falha operacional ao consultar o raciocínio: '
                    + e.getMessage() + '. Nenhuma causa foi confirmada.');
                return;
            }

            String acao = (String) decision.get('acao');
            String porque = (String) decision.get('porque');
            String capName = (String) decision.get('capacidade');
            String alvo = (String) decision.get('alvo');

            if (acao == 'concluir') {
                publishNarration('decisao', 'Já tenho o que preciso. Fechando o diagnóstico.');
                String resumo = (String) decision.get('resumo');
                String area = (String) decision.get('area');
                String impacto = (String) decision.get('impacto_negocio');
                Object correcao = decision.get('correcao');
                if (correcao != null) {
                    publishNarration('decisao', 'Tenho uma correção pra propor — vou pedir sua autorização antes de qualquer coisa.');
                    publishFix(JSON.serialize(correcao));
                }
                if (String.isNotBlank(impacto)) { publishImpact(impacto); }
                publishCost();
                publishSummary(resumo);
                String status = (area == 'externo') ? 'Fora do alcance' : 'Concluída';
                saveInvestigation(resumo, impacto, area, iter, status);
                return;
            }

            // Incidente vago: o agente pede esclarecimento em vez de adivinhar.
            if (acao == 'perguntar') {
                String pergunta = (String) decision.get('pergunta');
                publishQuestion(String.isBlank(pergunta) ? 'Pode detalhar mais o incidente?' : pergunta);
                return;
            }

            // Tolerante: às vezes a Claude põe a capacidade direto no 'acao'.
            if (String.isBlank(capName) && acao != 'rodar') {
                capName = acao;
            }
            if (String.isBlank(capName)) {
                publishSummary('Investigação encerrada: a decisão do raciocínio não foi reconhecida.');
                return;
            }

            // Executa a capacidade. Erro inesperado (ex.: orçamento de callout) encerra com honestidade.
            try {
                runCapability(capName, decision, porque, alvo);
            } catch (Exception e) {
                publishNarration('pensando', 'Bati num limite de execução. Vou fechar com o que já tenho.');
                publishSummary('Investigação encerrada por um limite operacional (' + e.getMessage()
                    + '). Segui até onde o org permitiu nesta rodada.');
                return;
            }
            // loop continua para o próximo passo
        }

        publishNarration('pensando', 'Já investiguei bastante. Vou fechar com o que tenho.');
        String semCausa = 'Investigação encerrada por limite de passos, sem uma causa 100% confirmada. Recomendo revisar manualmente os sinais já levantados.';
        publishSummary(semCausa);
        saveInvestigation(semCausa, null, 'inconclusivo', MAX_ITERATIONS, 'Inconclusiva');
    }

    // Despacha a decisão pra capacidade certa (sem re-enfileirar — o loop continua sozinho).
    private void runCapability(String capName, Map<String, Object> decision, String porque, String alvo) {
        usedCaps.add(capName);
        publishTool(capName);   // acende a capacidade no painel da tela
        if (capName == 'listar_classes') { runListClasses(porque); return; }
        if (capName == 'inspecionar_codigo') { runInspectCode(alvo, porque); return; }
        if (capName == 'testar_codigo') { runTest((String) decision.get('codigo_teste'), porque); return; }
        if (capName == 'sondar_integracao') { runProbe((String) decision.get('endpoint'), porque); return; }
        if (capName == 'buscar_no_codigo') { runBuscarCodigo((String) decision.get('termo'), porque); return; }
        if (capName == 'schema_objeto') { runSchema((String) decision.get('objeto'), porque); return; }
        if (capName == 'consultar_dados') { runConsultarDados((String) decision.get('soql'), porque); return; }
        if (capName == 'ler_debug_logs') { runDebugLogs(porque); return; }

        InvestigationCapability cap = CapabilityRegistry.resolve(capName);
        if (cap == null) {
            publishNarration('pensando', 'Pensei numa verificação que não tenho. Vou seguir com outra.');
            findings.add(capName + ': capacidade desconhecida, ignorada.');
            return;
        }
        runSignal(cap, capName, porque);
    }

    // --- Handlers de cada tipo de passo (sem enqueue — só fazem o trabalho e voltam ao loop) ---

    private void runListClasses(String porque) {
        publishNarration('decisao', 'Vou ver quais classes existem pra investigar. ' + safe(porque));
        publishNarration('acao', 'Listando as classes do org…');
        List<String> names = readUnmanagedClassNames();
        String nomes = names.isEmpty() ? '(nenhuma)' : String.join(names, ', ');
        publishNarration('achado', 'Classes de negócio disponíveis: ' + nomes);
        findings.add('classes_disponiveis: ' + nomes);
        publishNarration('pensando', 'Deixa eu pensar qual delas olhar…');
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
        publishNarration('pensando', 'Analisando o código de ' + safe(alvo) + '…');
    }

    private void runTest(String codigoTeste, String porque) {
        if (String.isBlank(codigoTeste)) {
            publishNarration('pensando', 'Quis testar mas não montei o código do teste. Vou seguir.');
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
    }

    private void runProbe(String endpoint, String porque) {
        if (String.isBlank(endpoint)) {
            publishNarration('pensando', 'Quis sondar uma integração mas não achei o endpoint. Vou seguir.');
            return;
        }

        // Callout DIRETO (o Queueable já permite callout), PRIMEIRO. É GET (só leitura), nunca POST.
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
    }

    // Traduz a exceção da sonda em ONDE está o problema (dentro do org vs fora).
    @TestVisible
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

    // Grep: procura um termo em TODAS as classes de negócio de uma vez.
    private void runBuscarCodigo(String termo, String porque) {
        if (String.isBlank(termo)) {
            publishNarration('pensando', 'Quis buscar no código mas não defini o termo. Vou seguir.');
            return;
        }
        publishNarration('decisao', 'Vou procurar "' + termo + '" em todo o código. ' + safe(porque));
        publishNarration('acao', 'Buscando "' + termo + '" nas classes…');

        String alvo = termo.toLowerCase();
        List<String> hits = new List<String>();
        for (ApexClass c : [SELECT Name, Body FROM ApexClass WHERE NamespacePrefix = null]) {
            if (FRAMEWORK.contains(c.Name) || c.Name.endsWith('Test') || c.Body == null) {
                continue;
            }
            String[] linhas = c.Body.split('\n');
            for (Integer i = 0; i < linhas.size(); i++) {
                if (linhas[i].toLowerCase().contains(alvo)) {
                    hits.add(c.Name + ':' + (i + 1) + '  ' + linhas[i].trim());
                }
            }
        }

        if (hits.isEmpty()) {
            publishNarration('descartado', 'Não achei "' + termo + '" em nenhuma classe de negócio.');
            findings.add('buscar_no_codigo(' + termo + '): nenhum resultado.');
        } else {
            List<String> mostra = new List<String>();
            for (Integer i = 0; i < Math.min(12, hits.size()); i++) {
                mostra.add(hits[i]);
            }
            publishNarration('achado', hits.size() + ' ocorrência(s) de "' + termo + '": ' + String.join(mostra, ' | '));
            findings.add('buscar_no_codigo(' + termo + '): ' + hits.size() + ' ocorrências: ' + String.join(hits, ' | '));
        }
        publishNarration('pensando', 'Vendo aonde isso me leva…');
    }

    // Descreve os campos (nome + tipo) de um objeto — o modelo de dados.
    private void runSchema(String objeto, String porque) {
        if (String.isBlank(objeto)) {
            publishNarration('pensando', 'Quis ver o schema mas não defini o objeto. Vou seguir.');
            return;
        }
        publishNarration('decisao', 'Vou ver os campos de "' + objeto + '". ' + safe(porque));
        Schema.SObjectType t = Schema.getGlobalDescribe().get(objeto);
        if (t == null) {
            publishNarration('descartado', 'O objeto "' + objeto + '" não existe neste org.');
            findings.add('schema_objeto(' + objeto + '): objeto não encontrado.');
            return;
        }
        List<String> campos = new List<String>();
        for (Schema.SObjectField f : t.getDescribe().fields.getMap().values()) {
            Schema.DescribeFieldResult d = f.getDescribe();
            campos.add(d.getName() + ' (' + d.getType() + ')');
        }
        publishNarration('achado', objeto + ' tem ' + campos.size() + ' campos: ' + String.join(campos, ', '));
        findings.add('schema_objeto(' + objeto + '): ' + String.join(campos, ', '));
        publishNarration('pensando', 'Agora sei o que posso consultar em ' + objeto + '…');
    }

    // Consulta SOQL de LEITURA nos dados reais. Amarras: só SELECT + guarda de privacidade.
    private void runConsultarDados(String soql, String porque) {
        if (String.isBlank(soql)) {
            publishNarration('pensando', 'Quis consultar dados mas não montei a query. Vou seguir.');
            return;
        }
        String q = soql.trim();
        String qLower = q.toLowerCase();
        if (!qLower.startsWith('select')) {
            publishNarration('descartado', 'Recusei uma consulta que não era SELECT — só leitura é permitida.');
            findings.add('consultar_dados: recusado (não-SELECT): ' + q);
            return;
        }

        // Guarda de PRIVACIDADE: nunca puxa dado pessoal. Conta/agrega, não expõe indivíduos.
        for (String pii : PII_TOKENS) {
            if (qLower.contains(pii)) {
                publishNarration('descartado',
                    'Recusei por PRIVACIDADE: a consulta tocaria em dado pessoal ("' + pii + '"). ' +
                    'Eu investigo fundo, mas não acesso dados de pessoas — uso contagem/agregado no lugar.');
                findings.add('consultar_dados: RECUSADO por privacidade (campo "' + pii + '"). Prefira COUNT()/agregado.');
                return;
            }
        }

        publishNarration('decisao', 'Vou consultar os dados reais pra confirmar. ' + safe(porque));
        publishTest('Consulta (SOQL)', q);
        publishNarration('acao', 'Rodando a consulta ao vivo…');

        // COUNT() agregado exige Database.countQuery (não Database.query).
        Boolean isCount = qLower.replaceAll('\\s+', '').startsWith('selectcount()');

        try {
            if (isCount) {
                Integer total = Database.countQuery(q);
                publishTestResult('> Resultado: ' + total + ' registro(s).');
                publishNarration('achado', 'A consulta contou ' + total + ' registro(s) nos dados reais.');
                findings.add('consultar_dados(' + q + '): COUNT = ' + total + '.');
            } else {
                List<SObject> rows = Database.query(q);
                String amostra = '(sem registros)';
                if (!rows.isEmpty()) {
                    List<SObject> primeiros = new List<SObject>();
                    for (Integer i = 0; i < Math.min(3, rows.size()); i++) {
                        primeiros.add(rows[i]);
                    }
                    amostra = JSON.serialize(primeiros);
                    if (amostra.length() > 1500) {
                        amostra = amostra.substring(0, 1500) + '…';
                    }
                }
                publishTestResult('> ' + rows.size() + ' registro(s).\nAmostra: ' + amostra);
                publishNarration('achado', 'A consulta retornou ' + rows.size() + ' registro(s).');
                findings.add('consultar_dados(' + q + '): ' + rows.size() + ' registros. Amostra: ' + amostra);
            }
        } catch (Exception e) {
            publishTestResult('> Erro na consulta:\n' + e.getMessage());
            publishNarration('descartado', 'A consulta falhou: ' + e.getMessage());
            findings.add('consultar_dados(' + q + '): erro: ' + e.getMessage());
        }
        publishNarration('pensando', 'Analisando os dados que voltaram…');
    }

    // Lê os logs de debug (runtime). SOQL nos ApexLog + baixa o corpo do mais recente (callout).
    private void runDebugLogs(String porque) {
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
            findings.add('ler_debug_logs: erro de acesso: ' + e.getMessage());
            return;
        }

        if (logs.isEmpty()) {
            publishNarration('descartado', 'Nenhum log de debug recente — a trace flag pode estar desligada.');
            findings.add('ler_debug_logs: nenhum log recente.');
            return;
        }

        // Baixa o corpo do log mais recente (callout).
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
        findings.add('ler_debug_logs: ' + String.join(meta, ' | ') + '. Trecho do mais recente: ' + trecho);
        publishNarration('pensando', 'Analisando o rastro do runtime…');
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

    // --- Publicação de eventos (Investigation_Step__e é PublishImmediately -> chega ao vivo) ---

    // Pergunta de esclarecimento (incidente vago) — pausa e espera a resposta humana.
    private void publishQuestion(String pergunta) {
        publishNarration('pensando', 'O incidente está vago pra eu ir direto ao ponto. Vou perguntar antes de adivinhar.');
        EventBus.publish(new Investigation_Step__e(
            Investigation_Id__c = investigationId,
            Step_Type__c        = 'question',
            Message__c          = 'question',
            Payload__c          = pergunta
        ));
    }

    // Custo/uso desta investigação (consciência de produção).
    private void publishCost() {
        Integer tok = ClaudeService.getTokens();
        Decimal usd = ClaudeService.getCostUsd().setScale(4);
        Long dur = (startMs == null) ? 0 : (DateTime.now().getTime() - startMs);
        String txt = tok + ' tokens · ~$' + usd + ' · ' + Math.round(dur / 1000.0) + 's';
        EventBus.publish(new Investigation_Step__e(
            Investigation_Id__c = investigationId,
            Step_Type__c        = 'cost',
            Message__c          = 'cost',
            Payload__c          = txt
        ));
    }

    // Impacto em linguagem de NEGÓCIO (o "B2C simulator"): tradução do técnico pro executivo.
    private void publishImpact(String texto) {
        EventBus.publish(new Investigation_Step__e(
            Investigation_Id__c = investigationId,
            Step_Type__c        = 'impact',
            Message__c          = 'impact',
            Payload__c          = texto
        ));
    }

    // Grava a investigação como REGISTRO (memória institucional). Nunca derruba a investigação.
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

    // Sinaliza qual capacidade está sendo usada (acende o painel de capacidades na tela).
    private void publishTool(String capName) {
        EventBus.publish(new Investigation_Step__e(
            Investigation_Id__c = investigationId,
            Step_Type__c        = 'tool',
            Message__c          = capName,
            Payload__c          = null
        ));
    }

    // Status de "pensando" — atualiza o indicador vivo da tela, sem virar item do histórico.
    private void publishThinking(String texto) {
        EventBus.publish(new Investigation_Step__e(
            Investigation_Id__c = investigationId,
            Step_Type__c        = 'thinking',
            Message__c          = 'thinking',
            Payload__c          = texto
        ));
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
