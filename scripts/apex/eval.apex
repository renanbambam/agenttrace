/**
 * Roda a suíte de avaliação do agente (evals) contra a Claude real e imprime o placar.
 *   sf apex run --file scripts/apex/eval.apex -o agenttrace-org
 *
 * Cada linha [PASSOU]/[FALHOU] é um cenário conhecido; o PLACAR no fim é o quanto o
 * agente acerta. É a prova de "eu verifico que meu sistema de IA funciona".
 */
for (String linha : AgentEval.run()) {
    System.debug('EVAL ' + linha);
}
