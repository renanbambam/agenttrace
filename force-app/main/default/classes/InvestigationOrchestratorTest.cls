/**
 * Testes do loop com TOOL_USE. Cada método finge uma escolha de ferramenta da Claude
 * (AgentTraceHttpMock em modo tool_use) e verifica que o ramo roda sem erro.
 * Para ferramentas que não são "concluir", o mock repete a mesma escolha até o limite
 * de passos — cobre a capacidade + o caminho de limite.
 */
@isTest
private class InvestigationOrchestratorTest {

    private static void runTool(String toolName, Map<String, Object> input) {
        Test.setMock(HttpCalloutMock.class, new AgentTraceHttpMock(toolName, input));
        Test.startTest();
        InvestigationOrchestrator.start('incidente de teste');
        Test.stopTest();
    }

    @isTest
    static void conclui() {
        runTool('concluir', new Map<String, Object>{
            'resumo' => 'conclusao de teste', 'area' => 'codigo', 'impacto_negocio' => '12 pedidos afetados' });
        System.assertEquals(1, [SELECT COUNT() FROM Investigacao__c], 'deve gravar o registro');
    }

    @isTest
    static void concluiComCorrecao() {
        runTool('concluir', new Map<String, Object>{
            'resumo' => 'r', 'area' => 'codigo', 'impacto_negocio' => 'x',
            'correcao' => new Map<String, Object>{ 'classe' => 'C', 'de' => 'a', 'para' => 'b', 'porque' => 'c' } });
    }

    @isTest
    static void concluiExterno() {
        runTool('concluir', new Map<String, Object>{ 'resumo' => 'r', 'area' => 'externo', 'impacto_negocio' => 'x' });
    }

    @isTest
    static void pergunta() {
        runTool('perguntar', new Map<String, Object>{ 'pergunta' => 'qual a area afetada?' });
    }

    @isTest
    static void semFerramenta_conclui() {
        Test.setMock(HttpCalloutMock.class, new AgentTraceHttpMock('conclusao em texto livre'));
        Test.startTest();
        InvestigationOrchestrator.start('inc');
        Test.stopTest();
    }

    @isTest static void listaClasses() { runTool('listar_classes', null); }
    @isTest static void inspecionaCodigo() { runTool('inspecionar_codigo', new Map<String, Object>{ 'alvo' => 'CalculadoraPedido' }); }
    @isTest static void inspecionaInexistente() { runTool('inspecionar_codigo', new Map<String, Object>{ 'alvo' => 'NaoExiste' }); }
    @isTest static void testaCodigo() { runTool('testar_codigo', new Map<String, Object>{ 'codigo_teste' => 'System.assert(false);' }); }
    @isTest static void sonda() { runTool('sondar_integracao', new Map<String, Object>{ 'endpoint' => 'https://api.exemplo.com/x' }); }

    @isTest
    static void sondaFalha() {
        AgentTraceHttpMock m = new AgentTraceHttpMock('sondar_integracao', new Map<String, Object>{ 'endpoint' => 'https://api.exemplo.com/x' });
        m.probeThrow = true;
        Test.setMock(HttpCalloutMock.class, m);
        Test.startTest();
        InvestigationOrchestrator.start('inc');
        Test.stopTest();
    }

    @isTest static void buscaCodigo() { runTool('buscar_no_codigo', new Map<String, Object>{ 'termo' => 'desconto' }); }
    @isTest static void schema() { runTool('schema_objeto', new Map<String, Object>{ 'objeto' => 'Log_Erro__c' }); }
    @isTest static void schemaInexistente() { runTool('schema_objeto', new Map<String, Object>{ 'objeto' => 'NaoExiste__x' }); }

    @isTest
    static void consultaDados() {
        insert new Log_Erro__c(Origem__c = 'X', Nivel__c = 'ERROR', Mensagem__c = 'falha');
        runTool('consultar_dados', new Map<String, Object>{ 'soql' => 'SELECT COUNT() FROM Log_Erro__c' });
    }

    @isTest static void consultaNaoSelect() { runTool('consultar_dados', new Map<String, Object>{ 'soql' => 'DELETE FROM Log_Erro__c' }); }
    @isTest static void consultaPrivacidade() { runTool('consultar_dados', new Map<String, Object>{ 'soql' => 'SELECT Email FROM Contact' }); }
    @isTest static void consultaErro() { runTool('consultar_dados', new Map<String, Object>{ 'soql' => 'SELECT Id FROM ObjetoInexistente__c' }); }
    @isTest static void lerLogs() { runTool('ler_debug_logs', null); }
    @isTest static void automacoes() { runTool('listar_automacoes', null); }
    @isTest static void limites() { runTool('verificar_limites', null); }
    @isTest static void capacidadeDesconhecida() { runTool('nao_existe', null); }

    @isTest
    static void falhaOperacional() {
        AgentTraceHttpMock m = new AgentTraceHttpMock('listar_classes', null);
        m.claudeStatus = 500;
        Test.setMock(HttpCalloutMock.class, m);
        Test.startTest();
        InvestigationOrchestrator.start('inc');
        Test.stopTest();
    }

    @isTest
    static void localizeIntegration_classificaTodos() {
        System.assert(InvestigationOrchestrator.localizeIntegration('Unauthorized endpoint').contains('org'));
        System.assert(InvestigationOrchestrator.localizeIntegration('HTTP 407 proxy').toLowerCase().contains('proxy'));
        System.assert(InvestigationOrchestrator.localizeIntegration('Read timed out').toLowerCase().contains('timeout'));
        System.assert(InvestigationOrchestrator.localizeIntegration('UnknownHost api.x.com').toLowerCase().contains('dns'));
        System.assertNotEquals(null, InvestigationOrchestrator.localizeIntegration('algo estranho'));
    }
}
