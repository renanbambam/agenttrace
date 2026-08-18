public with sharing class ValidadorEstoque {
    // Diz se há estoque suficiente para atender um pedido.
    // BUG: usa > em vez de >=, então quando a quantidade pedida é exatamente igual
    // ao estoque disponível, ele nega o pedido indevidamente.
    public static Boolean temEstoque(Integer disponivel, Integer pedido) {
        return disponivel > pedido;
    }
}
