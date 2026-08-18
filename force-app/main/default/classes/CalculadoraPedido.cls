public with sharing class CalculadoraPedido {
    // Aplica 10% de desconto para pedidos a partir de R$ 100.
    // BUG: usa > em vez de >=, então um pedido de exatamente R$ 100 não recebe desconto.
    public static Decimal calcularDesconto(Decimal valor) {
        if (valor > 100) {
            return valor * 0.10;
        }
        return 0;
    }
}
