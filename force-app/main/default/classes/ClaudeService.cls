/**
 * Serviço de callout à Claude API (Anthropic).
 *
 * A chave nunca aparece aqui: o Named Credential "Anthropic" injeta x-api-key e
 * anthropic-version a partir do cofre (External Credential). O modelo vem do
 * Custom Metadata Claude_Config__mdt (editável no Setup, sem deploy).
 */
public with sharing class ClaudeService {

    private static final String NAMED_CREDENTIAL = 'callout:Anthropic';
    private static final String FALLBACK_MODEL = 'claude-sonnet-5';

    public class ClaudeException extends Exception {}

    /** Modelo configurado no Custom Metadata (fallback se não houver registro). */
    private static String getModel() {
        Claude_Config__mdt cfg = Claude_Config__mdt.getInstance('Default');
        if (cfg != null && String.isNotBlank(cfg.Model__c)) {
            return cfg.Model__c;
        }
        return FALLBACK_MODEL;
    }

    /** Núcleo do callout: manda system + mensagens, devolve o texto da resposta. */
    private static String callClaude(String systemPrompt, List<Object> messages) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(NAMED_CREDENTIAL + '/v1/messages');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(120000);

        Map<String, Object> body = new Map<String, Object>{
            'model' => getModel(),
            'max_tokens' => 1024,
            'messages' => messages
        };
        if (String.isNotBlank(systemPrompt)) {
            body.put('system', systemPrompt);
        }
        req.setBody(JSON.serialize(body));

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            throw new ClaudeException(
                'Claude HTTP ' + res.getStatusCode() + ': ' + res.getBody()
            );
        }
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        accumulateUsage(parsed);
        return extractText(parsed);
    }

    // --- Custo/uso: acumulado por transação (= por investigação, já que o loop roda numa transação) ---
    private static Integer tokensIn = 0;
    private static Integer tokensOut = 0;

    // Preço estimado do modelo padrão (Sonnet), USD por 1M tokens. É estimativa, não fatura.
    private static final Decimal PRECO_IN = 3.0;
    private static final Decimal PRECO_OUT = 15.0;

    public static void resetUsage() { tokensIn = 0; tokensOut = 0; }
    public static Integer getTokens() { return tokensIn + tokensOut; }
    public static Decimal getCostUsd() {
        return (tokensIn / 1000000.0) * PRECO_IN + (tokensOut / 1000000.0) * PRECO_OUT;
    }

    private static void accumulateUsage(Map<String, Object> parsed) {
        Object u = parsed.get('usage');
        if (u instanceof Map<String, Object>) {
            Map<String, Object> usage = (Map<String, Object>) u;
            tokensIn += toInt(usage.get('input_tokens'));
            tokensOut += toInt(usage.get('output_tokens'));
        }
    }

    private static Integer toInt(Object o) {
        return o == null ? 0 : Integer.valueOf(String.valueOf(o));
    }

    /** Ping simples: prova o canal seguro ponta a ponta. */
    public static String ping(String prompt) {
        return callClaude(null, new List<Object>{
            new Map<String, Object>{ 'role' => 'user', 'content' => prompt }
        });
    }

    /**
     * Decide o próximo passo da investigação.
     * Recebe o incidente e os achados até agora; devolve a decisão parseada:
     *   {acao:'rodar', capacidade:'<nome>', porque:'...'}  ou
     *   {acao:'concluir', resumo:'...'}
     */
    public static Map<String, Object> decideNextStep(String incident, List<String> findings) {
        String systemPrompt = buildSystemPrompt();
        String userMsg = buildUserMessage(incident, findings);

        String raw = callClaude(systemPrompt, new List<Object>{
            new Map<String, Object>{ 'role' => 'user', 'content' => userMsg }
        });

        return parseDecision(raw);
    }

    /**
     * Gera um Apex anônimo que PROVA que uma correção funciona: implementa a lógica
     * JÁ CORRIGIDA inline e faz System.assertEquals do valor correto. Se a correção
     * funciona, o teste passa. Usado quando o humano autoriza a correção proposta.
     */
    public static String gerarVerificacao(String correcaoJson) {
        Map<String, Object> c = (Map<String, Object>) JSON.deserializeUntyped(correcaoJson);
        String systemPrompt =
            'Você gera UM bloco curto de Apex anônimo que PROVA que uma correção de código funciona. '
            + 'Responda APENAS com o código Apex, sem markdown, sem cercas, sem explicação. '
            + 'O código deve implementar a LÓGICA CORRIGIDA inline (NÃO chame a classe original, que ainda '
            + 'tem o bug) e usar System.assertEquals com o valor CORRETO esperado, de modo que, se a correção '
            + 'funciona, o teste passa. É só verificação de leitura; NUNCA faça DML.';
        String userMsg =
            'Classe: ' + c.get('classe') + '\n'
            + 'Trecho com bug (de): ' + c.get('de') + '\n'
            + 'Trecho corrigido (para): ' + c.get('para') + '\n'
            + 'Por que corrige: ' + c.get('porque') + '\n\n'
            + 'Gere o Apex anônimo que prova, executando, que a versão corrigida passa.';

        String raw = callClaude(systemPrompt, new List<Object>{
            new Map<String, Object>{ 'role' => 'user', 'content' => userMsg }
        });
        return stripCodeFences(raw);
    }

    /**
     * Raciocínio com TOOL_USE NATIVO (function calling da Anthropic).
     * Recebe o array de mensagens da conversa (com tool_result de volta), manda as
     * ferramentas, e devolve o bloco tool_use escolhido (ou o texto final).
     */
    public static Map<String, Object> reason(List<Object> messages) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(NAMED_CREDENTIAL + '/v1/messages');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(120000);

        Map<String, Object> body = new Map<String, Object>{
            'model' => getModel(),
            'max_tokens' => 1024,
            'system' => buildToolSystemPrompt(),
            'tools' => buildTools(),
            'tool_choice' => new Map<String, Object>{ 'type' => 'auto', 'disable_parallel_tool_use' => true },
            'messages' => messages
        };
        req.setBody(JSON.serialize(body));

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            throw new ClaudeException('Claude HTTP ' + res.getStatusCode() + ': ' + res.getBody());
        }
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        accumulateUsage(parsed);

        List<Object> content = (List<Object>) parsed.get('content');
        Map<String, Object> out = new Map<String, Object>{
            'stopReason' => parsed.get('stop_reason'),
            'assistantContent' => content
        };
        String text = '';
        if (content != null) {
            for (Object o : content) {
                Map<String, Object> block = (Map<String, Object>) o;
                if (block.get('type') == 'text') {
                    text += (String) block.get('text');
                } else if (block.get('type') == 'tool_use') {
                    out.put('toolUseId', block.get('id'));
                    out.put('toolName', block.get('name'));
                    out.put('toolInput', block.get('input'));
                }
            }
        }
        out.put('text', text);
        return out;
    }

    private static Map<String, Object> strProp(String descricao) {
        return new Map<String, Object>{ 'type' => 'string', 'description' => descricao };
    }

    /** Monta as ferramentas: cada capacidade + concluir + perguntar. */
    private static List<Object> buildTools() {
        List<Object> tools = new List<Object>();
        for (CapabilityRegistry.CapabilityInfo c : CapabilityRegistry.available()) {
            Map<String, Object> props = new Map<String, Object>{ 'porque' => strProp('motivo curto do passo') };
            List<String> req = new List<String>();
            if (c.name == 'inspecionar_codigo') { props.put('alvo', strProp('nome exato da classe')); req.add('alvo'); }
            else if (c.name == 'testar_codigo') { props.put('codigo_teste', strProp('Apex anônimo com System.assertEquals, só leitura')); req.add('codigo_teste'); }
            else if (c.name == 'sondar_integracao') { props.put('endpoint', strProp('URL exata do endpoint')); req.add('endpoint'); }
            else if (c.name == 'buscar_no_codigo') { props.put('termo', strProp('texto/símbolo a procurar')); req.add('termo'); }
            else if (c.name == 'schema_objeto') { props.put('objeto', strProp('API name do objeto')); req.add('objeto'); }
            else if (c.name == 'consultar_dados') { props.put('soql', strProp('SELECT ... só leitura, nunca PII')); req.add('soql'); }
            tools.add(new Map<String, Object>{
                'name' => c.name, 'description' => c.description,
                'input_schema' => new Map<String, Object>{ 'type' => 'object', 'properties' => props, 'required' => req }
            });
        }
        // concluir
        tools.add(new Map<String, Object>{
            'name' => 'concluir',
            'description' => 'Fecha a investigação com o diagnóstico final. Use quando tiver a causa com evidência.',
            'input_schema' => new Map<String, Object>{
                'type' => 'object',
                'properties' => new Map<String, Object>{
                    'resumo' => strProp('parágrafo técnico: o que verificou, descartou, a causa com evidência específica, e a recomendação'),
                    'area' => strProp('uma palavra: codigo, dados, integracao, config, externo ou inconclusivo'),
                    'impacto_negocio' => strProp('1-2 frases em linguagem de EXECUTIVO — impacto no cliente/receita, sem jargão'),
                    'correcao' => new Map<String, Object>{
                        'type' => 'object',
                        'description' => 'só quando houver uma correção de código concreta',
                        'properties' => new Map<String, Object>{
                            'classe' => strProp('nome da classe'), 'de' => strProp('trecho EXATO com o bug'),
                            'para' => strProp('trecho corrigido'), 'porque' => strProp('por que corrige')
                        }
                    }
                },
                'required' => new List<String>{ 'resumo', 'area', 'impacto_negocio' }
            }
        });
        // perguntar
        tools.add(new Map<String, Object>{
            'name' => 'perguntar',
            'description' => 'Pede UM esclarecimento quando o incidente é vago demais pra investigar.',
            'input_schema' => new Map<String, Object>{
                'type' => 'object',
                'properties' => new Map<String, Object>{ 'pergunta' => strProp('uma pergunta objetiva') },
                'required' => new List<String>{ 'pergunta' }
            }
        });
        return tools;
    }

    private static String buildToolSystemPrompt() {
        return 'Você é um agente que investiga incidentes técnicos dentro de um org Salesforce. '
            + 'Use as FERRAMENTAS pra vasculhar (código, dados, integração, logs, config, jobs, automações) '
            + 'e, quando tiver a causa com evidência, chame a ferramenta "concluir". Chame UMA ferramenta a '
            + 'cada passo — nunca responda só com texto.\n\n'
            + 'Regras:\n'
            + '- Investigue FUNDO e cruze fontes pra achar causas não óbvias: rastreie símbolos no código, veja o schema, confirme nos DADOS reais. Forme uma HIPÓTESE e junte evidência de mais de uma fonte.\n'
            + '- PRIVACIDADE é inegociável: nunca acesse dado pessoal (email, telefone, CPF, endereço). Em consultar_dados use COUNT/agregados, jamais selecione PII.\n'
            + '- Nunca invente uma causa. Toda conclusão precisa de evidência específica. Só inclua "correcao" com o trecho EXATO a trocar (copiado do código); você propõe, o humano aplica.\n'
            + '- Para integração falhando: inspecione a classe, ache o endpoint, e sondar_integracao. "Unauthorized endpoint" = config no org; 407/timeout/DNS = rede/proxy externo, FORA do seu alcance — seja honesto.\n'
            + '- Se os logs mostram erro externo recorrente (407/timeout), isso JÁ localiza fora do org — conclua direto (area "externo"), sem sondar.\n'
            + '- Se o incidente for vago demais, use "perguntar" em vez de adivinhar. Não repita a mesma ferramenta com o mesmo alvo.';
    }

    // --- helpers ---

    /** Remove cercas de markdown (```apex ... ```) se a Claude escorregar e mandar. */
    private static String stripCodeFences(String raw) {
        String cleaned = raw == null ? '' : raw.trim();
        if (cleaned.startsWith('```')) {
            Integer firstBreak = cleaned.indexOf('\n');
            if (firstBreak > -1) {
                cleaned = cleaned.substring(firstBreak + 1);
            }
            if (cleaned.endsWith('```')) {
                cleaned = cleaned.substring(0, cleaned.length() - 3);
            }
            cleaned = cleaned.trim();
        }
        return cleaned;
    }

    private static String buildSystemPrompt() {
        String caps = '';
        for (CapabilityRegistry.CapabilityInfo c : CapabilityRegistry.available()) {
            caps += '- ' + c.name + ': ' + c.description + '\n';
        }
        return 'Você é um agente que investiga incidentes técnicos dentro de um org Salesforce. '
            + 'Você raciocina sobre ONDE pode estar o problema e decide, a cada passo, qual capacidade '
            + 'usar — ou conclui. Você se vira: descobre as classes, abre o código real, avalia se o '
            + 'método está bem escrito, e pode recomendar melhorias.\n\n'
            + 'Responda SEMPRE com UM ÚNICO objeto JSON válido, sem nenhum texto fora dele e sem markdown. '
            + 'Formatos aceitos:\n'
            + '{"acao":"rodar","capacidade":"<nome exato da lista>","porque":"<motivo curto>"}\n'
            + '{"acao":"rodar","capacidade":"inspecionar_codigo","alvo":"<nome exato da classe>","porque":"<motivo>"}\n'
            + '{"acao":"rodar","capacidade":"testar_codigo","codigo_teste":"<Apex anônimo com System.assertEquals chamando o método>","porque":"<motivo>"}\n'
            + '{"acao":"rodar","capacidade":"sondar_integracao","endpoint":"<URL exata do endpoint, extraída do código da classe de integração>","porque":"<motivo>"}\n'
            + '{"acao":"rodar","capacidade":"buscar_no_codigo","termo":"<texto/símbolo a procurar em todas as classes>","porque":"<motivo>"}\n'
            + '{"acao":"rodar","capacidade":"schema_objeto","objeto":"<API name do objeto>","porque":"<motivo>"}\n'
            + '{"acao":"rodar","capacidade":"consultar_dados","soql":"<SELECT ... só leitura>","porque":"<motivo>"}\n'
            + '{"acao":"perguntar","pergunta":"<UMA pergunta objetiva de esclarecimento>"}\n'
            + '{"acao":"concluir","resumo":"<parágrafo técnico: o que verificou, o que descartou, a causa provável com evidência específica, e a recomendação>","area":"<uma palavra: codigo, dados, integracao, config, externo ou inconclusivo>","impacto_negocio":"<1 a 2 frases em linguagem de EXECUTIVO — o impacto no cliente, na receita ou na operação, SEM jargão técnico. Ex.: quantos clientes/pedidos afetados e o risco de negócio>","correcao":{"classe":"<nome exato da classe>","de":"<trecho EXATO do código atual que contém o bug, copiado como está>","para":"<o mesmo trecho já corrigido>","porque":"<por que essa mudança corrige, em uma frase>"}}\n\n'
            + 'Regras:\n'
            + '- Se o incidente for VAGO demais pra saber por onde começar (sem pista de sintoma, área ou objeto), use "perguntar" com UMA pergunta objetiva de esclarecimento em vez de adivinhar — só no primeiro passo e só se realmente necessário. Se já der pra investigar, investigue.\n'
            + '- Nunca invente uma causa. Toda conclusão precisa de evidência específica (ex.: a linha do código, o número do achado, o resultado do teste).\n'
            + '- Só inclua "correcao" quando você tiver uma correção de código concreta: o trecho EXATO a trocar (copiado do código que você inspecionou) e a versão já corrigida. Se a causa está fora do seu alcance, ou você não tem o trecho exato, OMITA "correcao" — nunca invente uma correção. Você propõe; quem aplica é o humano.\n'
            + '- Para investigar código: primeiro use listar_classes pra descobrir os nomes, depois inspecionar_codigo com o nome exato. Ao ver o código, aponte o bug na linha específica se houver.\n'
            + '- Para PROVAR um bug: depois de inspecionar, use testar_codigo com um Apex que chama o método no caso de fronteira e faz System.assertEquals do valor CORRETO esperado — assim, se houver bug, o teste falha e expõe. Escreva SÓ verificação de leitura; NUNCA faça DML (insert/update/delete). Um teste que falha com a evidência é a prova mais forte pra sua conclusão.\n'
            + '- Investigue FUNDO e cruze fontes pra achar causas não óbvias: use buscar_no_codigo pra rastrear um símbolo pelo codebase inteiro, schema_objeto pra entender os campos de um objeto, e consultar_dados pra confirmar nos DADOS reais uma hipótese levantada no código (ex.: quantos registros um bug afetou). Forme uma HIPÓTESE, junte evidência de mais de uma fonte, e só conclua quando a evidência sustentar.\n'
            + '- consultar_dados é SÓ SELECT (leitura). NUNCA tente modificar dados (nada de INSERT/UPDATE/DELETE); o Apex recusa e você perde o passo.\n'
            + '- PRIVACIDADE é inegociável: você revira o org inteiro pra achar problemas, mas NUNCA acessa dado pessoal de indivíduos (email, telefone, CPF, RG, endereço, data de nascimento, etc.). Em consultar_dados, prefira COUNT()/agregados e campos estruturais; jamais selecione campos de PII (o Apex recusa). Pra saber "quantos", conte — não puxe os dados das pessoas.\n'
            + '- Não rode a mesma capacidade (com o mesmo alvo) duas vezes.\n'
            + '- Para incidentes onde algo "parou" ou "deu erro" e você não sabe ONDE: comece por log_erro pra ver o que já foi registrado. Se os logs mostram falha de rede/proxy externo (407, timeout, DNS) recorrente ligada a um endpoint, isso JÁ localiza a causa FORA do org — conclua DIRETO com honestidade e aponte a infraestrutura externa; NÃO vá procurar classe nem sondar (uma sonda de dentro do org não diagnostica rede/proxy externo), e NÃO invente correção de código.\n'
            + '- Para incidentes de INTEGRAÇÃO/callout falhando: primeiro inspecione a classe de integração pra achar o ENDPOINT (a URL), depois use sondar_integracao com esse endpoint pra observar a falha REAL ao vivo. Ao ler o resultado, localize a causa: "Unauthorized endpoint" significa config DENTRO do org (recomende liberar o endpoint em Remote Site Settings ou usar Named Credential); 407/timeout/DNS/UnknownHost significa rede/proxy externo, FORA do seu alcance — seja honesto e aponte o que verificar por fora. Nunca rode métodos de escrita (POST) da integração; a sonda já é só leitura.\n'
            + '- Seu alcance é SÓ este org Salesforce. Se o problema aparentar ser algo fora daqui (rede, proxy, sistema externo), seja honesto: conclua dizendo que está fora do seu alcance e recomende o que verificar por fora.\n'
            + '- Se os achados não sustentam uma conclusão, rode outra capacidade ou conclua com honestidade que não foi conclusivo.\n\n'
            + 'Capacidades disponíveis:\n' + caps;
    }

    private static String buildUserMessage(String incident, List<String> findings) {
        String msg = 'Incidente: ' + incident + '\n\n';
        if (findings == null || findings.isEmpty()) {
            msg += 'Nenhuma capacidade rodada ainda. Qual é o primeiro passo?';
        } else {
            msg += 'Achados até agora:\n';
            for (String f : findings) {
                msg += '- ' + f + '\n';
            }
            msg += '\nQual o próximo passo: rodar outra capacidade ou concluir?';
        }
        return msg;
    }

    private static Map<String, Object> parseDecision(String raw) {
        String cleaned = raw == null ? '' : raw.trim();
        // Remove cercas de markdown se a Claude escorregar e mandar ```json ... ```
        if (cleaned.startsWith('```')) {
            Integer firstBreak = cleaned.indexOf('\n');
            if (firstBreak > -1) {
                cleaned = cleaned.substring(firstBreak + 1);
            }
            if (cleaned.endsWith('```')) {
                cleaned = cleaned.substring(0, cleaned.length() - 3);
            }
            cleaned = cleaned.trim();
        }
        try {
            return (Map<String, Object>) JSON.deserializeUntyped(cleaned);
        } catch (Exception e) {
            throw new ClaudeException('Resposta da Claude não é JSON válido: ' + raw);
        }
    }

    /** Extrai o primeiro bloco de texto do content[] da resposta já parseada. */
    private static String extractText(Map<String, Object> parsed) {
        List<Object> content = (List<Object>) parsed.get('content');
        if (content != null) {
            for (Object item : content) {
                Map<String, Object> block = (Map<String, Object>) item;
                if (block.get('type') == 'text') {
                    return (String) block.get('text');
                }
            }
        }
        return '';
    }
}
